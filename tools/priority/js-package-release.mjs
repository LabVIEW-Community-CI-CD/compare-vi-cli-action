#!/usr/bin/env node

import fs from 'node:fs';
import { cp, mkdir, readFile, readdir, rm, stat, writeFile } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import process from 'node:process';
import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { createSanitizedNpmEnv } from '../npm/sanitize-env.mjs';
import { createNpmLaunchSpec } from '../npm/spawn.mjs';

export const REPORT_SCHEMA = 'priority/js-package-release@v1';
export const DEFAULT_REGISTRY_URL = 'https://npm.pkg.github.com';
export const DEFAULT_REPORT_PATH = path.join('tests', 'results', '_agent', 'release', 'js-package-release-report.json');
export const STABLE_SEMVER_PATTERN = /^\d+\.\d+\.\d+$/;
export const RC_SEMVER_PATTERN = /^\d+\.\d+\.\d+-rc\.\d+$/;
export const ACTIONS = new Set(['resolve', 'stage', 'verify']);

const USAGE_LINES = [
  'Usage: node tools/priority/js-package-release.mjs --action <resolve|stage|verify> [options]',
  '',
  'Resolve, stage, and verify org-scoped JavaScript package release candidates.',
  '',
  'Common options:',
  '  --action <value>            Action to run (resolve, stage, verify).',
  '  --package-dir <path>        Package directory relative to the repo root.',
  '  --version <value>           Candidate version (required).',
  '  --channel <stable|rc>       Optional release channel override.',
  '  --publish <true|false>      Whether the candidate should be published.',
  '  --registry-url <url>        Registry URL (default: https://npm.pkg.github.com).',
  '  --repo <owner/repo>         Repository slug for generated metadata.',
  '  --owner <value>             Repository owner override.',
  '  --server-url <url>          GitHub server URL for metadata defaults.',
  '  --report <path>             JSON report output path.',
  '  --github-output <path>      GitHub Action output file path.',
  '',
  'Stage options:',
  '  --staging-dir <path>        Deterministic staging directory.',
  '  --tarball-dir <path>        Output directory for npm pack tarballs.',
  '  --copy-license-from <path>  Optional fallback license source path.',
  '',
  'Verify options:',
  '  --source-spec <value>       Tarball path or package spec to install.',
  '  --consumer-dir <path>       Clean consumer directory for install/import checks.',
  '  --token <value>             Registry token override (falls back to NODE_AUTH_TOKEN).',
  '  --install-retries <count>   Retry count for registry installs (default: 3).',
  '  --retry-delay-ms <count>    Delay between retries in milliseconds (default: 5000).',
  '',
  '  -h, --help                  Show this help text and exit.'
];

function printUsage() {
  for (const line of USAGE_LINES) {
    console.log(line);
  }
}

function normalizeText(value) {
  if (value == null) return '';
  return String(value).trim();
}

function trimToNull(value) {
  const normalized = normalizeText(value);
  return normalized.length > 0 ? normalized : null;
}

function readOptionValue(args, index, token) {
  const next = args[index + 1];
  if (typeof next === 'undefined' || (next.startsWith('-') && next.length > 0)) {
    throw new Error(`Missing value for ${token}.`);
  }
  return next;
}

function parseBoolean(value, label) {
  if (typeof value === 'boolean') {
    return value;
  }
  const normalized = normalizeText(value).toLowerCase();
  if (!normalized) {
    return false;
  }
  if (['1', 'true', 'yes', 'on'].includes(normalized)) {
    return true;
  }
  if (['0', 'false', 'no', 'off'].includes(normalized)) {
    return false;
  }
  throw new Error(`Invalid ${label} value '${value}'.`);
}

function parseInteger(value, { label, minimum = 0 } = {}) {
  const number = Number.parseInt(String(value ?? ''), 10);
  if (!Number.isInteger(number) || number < minimum) {
    throw new Error(`Invalid ${label} value '${value}'.`);
  }
  return number;
}

function resolveRepoRoot() {
  return path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..');
}

function resolvePath(repoRoot, value) {
  const normalized = trimToNull(value);
  if (!normalized) {
    return null;
  }
  return path.isAbsolute(normalized) ? normalized : path.join(repoRoot, normalized);
}

function isPathWithin(basePath, candidatePath) {
  const relativePath = path.relative(basePath, candidatePath);
  return relativePath === '' || (!relativePath.startsWith('..') && !path.isAbsolute(relativePath));
}

function ensureArray(value) {
  return Array.isArray(value) ? value : [];
}

function unique(values) {
  const seen = new Set();
  const result = [];
  for (const value of values) {
    const normalized = normalizeText(value);
    if (!normalized || seen.has(normalized)) {
      continue;
    }
    seen.add(normalized);
    result.push(normalized);
  }
  return result;
}

function uniqueResolvedPaths(values) {
  return unique(values.map((value) => path.resolve(String(value))));
}

function sanitizeExportTarget(target) {
  const normalized = normalizeText(target);
  if (!normalized.startsWith('./')) {
    return null;
  }
  return normalized;
}

function collectExportTargets(value, acc = []) {
  if (typeof value === 'string') {
    const normalized = sanitizeExportTarget(value);
    if (normalized) {
      acc.push(normalized);
    }
    return acc;
  }

  if (Array.isArray(value)) {
    for (const entry of value) {
      collectExportTargets(entry, acc);
    }
    return acc;
  }

  if (value && typeof value === 'object') {
    for (const entry of Object.values(value)) {
      collectExportTargets(entry, acc);
    }
  }

  return acc;
}

function deriveExportSpecifiers(packageName, packageJson) {
  const exportsField = packageJson?.exports;
  const specifiers = [];

  if (typeof exportsField === 'string' || Array.isArray(exportsField)) {
    specifiers.push(packageName);
  } else if (exportsField && typeof exportsField === 'object') {
    for (const subpath of Object.keys(exportsField)) {
      if (subpath === '.') {
        specifiers.push(packageName);
        continue;
      }
      if (subpath.startsWith('./')) {
        specifiers.push(`${packageName}/${subpath.slice(2)}`);
      }
    }
  } else if (trimToNull(packageJson?.main)) {
    specifiers.push(packageName);
  }

  return unique(specifiers);
}

function inferChannel(version, explicitChannel) {
  const channel = trimToNull(explicitChannel);
  if (channel) {
    return channel;
  }
  return version.includes('-rc.') ? 'rc' : 'stable';
}

function validateVersion(version, channel) {
  if (channel === 'stable') {
    if (!STABLE_SEMVER_PATTERN.test(version)) {
      throw new Error(`Stable channel requires X.Y.Z version. Received: ${version}`);
    }
    return;
  }

  if (channel === 'rc') {
    if (!RC_SEMVER_PATTERN.test(version)) {
      throw new Error(`RC channel requires X.Y.Z-rc.N version. Received: ${version}`);
    }
    return;
  }

  throw new Error(`Unsupported channel: ${channel}`);
}

function parsePackageName(packageName) {
  const match = /^(@[^/]+)\/([^/]+)$/.exec(normalizeText(packageName));
  if (!match) {
    throw new Error(`Expected a scoped package name. Received: ${packageName}`);
  }

  return {
    packageName: match[0],
    scope: match[1],
    scopeOwner: match[1].slice(1),
    unscopedName: match[2]
  };
}

function resolveOwner({ owner, repository }) {
  const explicitOwner = trimToNull(owner);
  if (explicitOwner) {
    return explicitOwner;
  }

  const repoSlug = trimToNull(repository);
  if (repoSlug && repoSlug.includes('/')) {
    return repoSlug.split('/')[0];
  }

  return null;
}

function defaultDistTag(channel) {
  return channel === 'rc' ? 'rc' : 'latest';
}

function formatGitUrl(serverUrl, repository) {
  return `git+${String(serverUrl || 'https://github.com').replace(/\/+$/, '')}/${repository}.git`;
}

function formatBugsUrl(serverUrl, repository) {
  return `${String(serverUrl || 'https://github.com').replace(/\/+$/, '')}/${repository}/issues`;
}

function formatHomepageUrl(serverUrl, repository) {
  return `${String(serverUrl || 'https://github.com').replace(/\/+$/, '')}/${repository}#readme`;
}

async function readJson(filePath) {
  return JSON.parse(await readFile(filePath, 'utf8'));
}

async function writeJson(filePath, payload) {
  await mkdir(path.dirname(filePath), { recursive: true });
  await writeFile(filePath, `${JSON.stringify(payload, null, 2)}\n`, 'utf8');
  return filePath;
}

async function findCaseInsensitiveMatch(dirPath, basename) {
  try {
    const entries = await readdir(dirPath);
    const match = entries.find((entry) => entry.toLowerCase() === basename.toLowerCase());
    return match ? path.join(dirPath, match) : null;
  } catch (error) {
    if (error?.code === 'ENOENT') {
      return null;
    }
    throw error;
  }
}

function normalizePackageRelativePath(packageDir, entry, label = 'package publish entry') {
  const normalizedValue = normalizeText(entry).replace(/\\/g, '/');
  if (!normalizedValue) {
    return null;
  }

  const withoutDotPrefix = normalizedValue.replace(/^\.\/+/, '');
  if (!withoutDotPrefix) {
    return null;
  }

  if (path.isAbsolute(withoutDotPrefix) || /^[A-Za-z]:/.test(withoutDotPrefix)) {
    throw new Error(`${label} '${entry}' must be relative to the package directory.`);
  }

  const segments = withoutDotPrefix.split('/').filter((segment) => segment && segment !== '.');
  if (segments.length === 0) {
    return null;
  }
  if (segments.includes('..')) {
    throw new Error(`${label} '${entry}' must stay within the package directory.`);
  }

  const normalizedPath = segments.join('/');
  const resolvedPath = path.resolve(packageDir, normalizedPath);
  if (!isPathWithin(path.resolve(packageDir), resolvedPath)) {
    throw new Error(`${label} '${entry}' must stay within the package directory.`);
  }

  return normalizedPath;
}

function resolveManagedDirectoryRoots(repoRoot) {
  return uniqueResolvedPaths([
    path.join(repoRoot, 'tests', 'results'),
    path.join(repoRoot, '.tmp'),
    os.tmpdir()
  ]);
}

function assertSafeManagedDirectory(targetPath, { label, allowedRoots, repoRoot }) {
  const normalizedLabel = normalizeText(label) || 'managed directory';
  const resolvedTargetPath = path.resolve(String(targetPath));
  const resolvedRepoRoot = path.resolve(repoRoot);
  const resolvedHomeDir = path.resolve(os.homedir());
  const filesystemRoot = path.parse(resolvedTargetPath).root;

  if (
    resolvedTargetPath === filesystemRoot ||
    resolvedTargetPath === resolvedRepoRoot ||
    resolvedTargetPath === resolvedHomeDir
  ) {
    throw new Error(`${normalizedLabel} '${targetPath}' is not a safe managed directory target.`);
  }

  const withinAllowedRoot = allowedRoots
    .map((rootPath) => path.resolve(rootPath))
    .some((rootPath) => isPathWithin(rootPath, resolvedTargetPath) && path.relative(rootPath, resolvedTargetPath) !== '');
  if (!withinAllowedRoot) {
    throw new Error(`${normalizedLabel} '${targetPath}' must stay within a managed directory root.`);
  }

  return resolvedTargetPath;
}

async function resolvePackagePublishEntries(packageDir, packageJson) {
  const explicitFiles = ensureArray(packageJson?.files);
  const entries = [];

  if (explicitFiles.length > 0) {
    for (const value of explicitFiles) {
      const normalized = normalizePackageRelativePath(packageDir, value, 'package.json files entry');
      if (!normalized) {
        continue;
      }
      if (/[?*\[\]{}]/.test(normalized)) {
        throw new Error(`Unsupported package.json files glob entry '${normalized}'.`);
      }
      entries.push(normalized);
    }
  } else {
    for (const candidate of [
      packageJson?.main,
      packageJson?.module,
      packageJson?.types,
      ...collectExportTargets(packageJson?.exports)
    ]) {
      const normalized = normalizePackageRelativePath(packageDir, candidate, 'package export entry');
      if (normalized) {
        entries.push(normalized);
      }
    }
  }

  const readmePath = await findCaseInsensitiveMatch(packageDir, 'README.md');
  if (readmePath) {
    entries.push(path.basename(readmePath));
  }

  return unique(entries);
}

function createCopyPlan(packageDir, entries) {
  const plan = [];
  for (const relativePath of entries) {
    const normalized = normalizePackageRelativePath(packageDir, relativePath);
    if (!normalized || normalized === 'package.json') {
      continue;
    }
    plan.push({ sourceRelativePath: normalized, destinationRelativePath: normalized });
  }
  return plan;
}

async function copyPlanEntries(packageDir, stagingDir, plan) {
  const copied = [];
  for (const entry of plan) {
    const sourcePath = path.join(packageDir, entry.sourceRelativePath);
    const destinationPath = path.join(stagingDir, entry.destinationRelativePath);
    const stats = await stat(sourcePath);
    await mkdir(path.dirname(destinationPath), { recursive: true });
    await cp(sourcePath, destinationPath, { recursive: stats.isDirectory(), force: true });
    copied.push(entry.destinationRelativePath);
  }
  return copied;
}

async function ensureLicenseFile({ packageDir, stagingDir, copyLicenseFrom }) {
  const packageLicense = await findCaseInsensitiveMatch(packageDir, 'LICENSE');
  const sourcePath = packageLicense ?? resolvePath(resolveRepoRoot(), copyLicenseFrom);
  if (!sourcePath || !fs.existsSync(sourcePath)) {
    return null;
  }

  const destinationPath = path.join(stagingDir, 'LICENSE');
  await mkdir(path.dirname(destinationPath), { recursive: true });
  await cp(sourcePath, destinationPath, { force: true });
  return destinationPath;
}

function buildStagedPackageJson(sourcePackageJson, context, publishEntries) {
  const next = {
    ...sourcePackageJson,
    version: context.version,
    private: false,
    publishConfig: {
      ...(sourcePackageJson.publishConfig ?? {}),
      registry: context.registryUrl
    },
    repository:
      sourcePackageJson.repository ??
      {
        type: 'git',
        url: formatGitUrl(context.serverUrl, context.repository)
      },
    homepage: sourcePackageJson.homepage ?? formatHomepageUrl(context.serverUrl, context.repository),
    bugs:
      sourcePackageJson.bugs ??
      {
        url: formatBugsUrl(context.serverUrl, context.repository)
      },
    files: unique(publishEntries.filter((entry) => entry !== 'package.json' && !entry.startsWith('LICENSE')))
  };

  return next;
}

function spawnChild(command, args, options = {}) {
  return new Promise((resolve, reject) => {
    const child = spawn(command, args, {
      cwd: options.cwd,
      env: options.env,
      stdio: ['ignore', 'pipe', 'pipe']
    });

    let stdout = '';
    let stderr = '';

    child.stdout.on('data', (chunk) => {
      stdout += chunk.toString();
    });
    child.stderr.on('data', (chunk) => {
      stderr += chunk.toString();
    });

    child.on('error', reject);
    child.on('close', (exitCode, signal) => {
      resolve({
        command,
        args,
        cwd: options.cwd ?? process.cwd(),
        exitCode: exitCode ?? (signal ? 1 : 0),
        signal: signal ?? null,
        stdout,
        stderr
      });
    });
  });
}

async function runNpmCommand(args, options = {}) {
  const env = {
    ...createSanitizedNpmEnv(process.env),
    ...(options.env ?? {})
  };
  const launchSpec = createNpmLaunchSpec(args, env);
  const result = await spawnChild(launchSpec.command, launchSpec.args, {
    cwd: options.cwd,
    env
  });
  if (result.exitCode !== 0) {
    const details = normalizeText(result.stderr) || normalizeText(result.stdout) || `npm exited ${result.exitCode}`;
    throw new Error(details);
  }
  return {
    ...result,
    displayCommand: [launchSpec.command, ...launchSpec.args].join(' ')
  };
}

async function runNodeEval(script, options = {}) {
  const result = await spawnChild(process.execPath, ['--input-type=module', '--eval', script], options);
  if (result.exitCode !== 0) {
    const details = normalizeText(result.stderr) || normalizeText(result.stdout) || `node exited ${result.exitCode}`;
    throw new Error(details);
  }
  return result;
}

async function sleep(ms) {
  if (ms <= 0) {
    return;
  }
  await new Promise((resolve) => setTimeout(resolve, ms));
}

function looksLikeRegistryPackageSpec(sourceSpec) {
  return /^(?:@[^/]+\/)?[^/@]+(?:@[^/]+)?$/.test(sourceSpec);
}

function detectSourceMode(sourceSpec) {
  const normalized = normalizeText(sourceSpec);
  if (!normalized) {
    return 'registry';
  }
  if (normalized.endsWith('.tgz') || normalized.endsWith('.tar.gz')) {
    return 'tarball';
  }
  if (looksLikeRegistryPackageSpec(normalized)) {
    return 'registry';
  }
  if (
    path.isAbsolute(normalized) ||
    normalized.startsWith('.') ||
    normalized.includes(path.sep) ||
    normalized.includes('/')
  ) {
    return 'tarball';
  }
  return 'registry';
}

function buildScopedNpmrc({ scope, registryUrl, token }) {
  const registry = new URL(registryUrl);
  const pathPrefix = registry.pathname.endsWith('/') ? registry.pathname : `${registry.pathname}/`;
  const authTarget = `${registry.host}${pathPrefix}`;
  return [
    `${scope}:registry=${registryUrl}`,
    `//${authTarget}:_authToken=${token}`,
    'always-auth=true'
  ].join('\n');
}

function formatPackageSpec(packageName, version) {
  return `${packageName}@${version}`;
}

function formatNow(now = new Date()) {
  return now.toISOString();
}

export function parseArgs(argv = process.argv) {
  const args = argv.slice(2);
  const options = {
    action: '',
    packageDir: '',
    version: '',
    channel: '',
    publish: false,
    registryUrl: DEFAULT_REGISTRY_URL,
    repository: trimToNull(process.env.GITHUB_REPOSITORY),
    owner: trimToNull(process.env.GITHUB_REPOSITORY_OWNER),
    serverUrl: trimToNull(process.env.GITHUB_SERVER_URL) ?? 'https://github.com',
    reportPath: DEFAULT_REPORT_PATH,
    githubOutputPath: trimToNull(process.env.GITHUB_OUTPUT),
    stagingDir: '',
    tarballDir: '',
    copyLicenseFrom: 'LICENSE',
    sourceSpec: '',
    consumerDir: '',
    token: trimToNull(process.env.NODE_AUTH_TOKEN ?? process.env.GITHUB_TOKEN ?? process.env.GH_TOKEN),
    installRetries: 3,
    retryDelayMs: 5000,
    help: false
  };

  for (let index = 0; index < args.length; index += 1) {
    const token = args[index];
    if (token === '--help' || token === '-h') {
      options.help = true;
      continue;
    }

    if (
      token === '--action' ||
      token === '--package-dir' ||
      token === '--version' ||
      token === '--channel' ||
      token === '--publish' ||
      token === '--registry-url' ||
      token === '--repo' ||
      token === '--owner' ||
      token === '--server-url' ||
      token === '--report' ||
      token === '--github-output' ||
      token === '--staging-dir' ||
      token === '--tarball-dir' ||
      token === '--copy-license-from' ||
      token === '--source-spec' ||
      token === '--consumer-dir' ||
      token === '--token' ||
      token === '--install-retries' ||
      token === '--retry-delay-ms'
    ) {
      const value = readOptionValue(args, index, token);
      index += 1;

      if (token === '--action') options.action = normalizeText(value).toLowerCase();
      if (token === '--package-dir') options.packageDir = normalizeText(value);
      if (token === '--version') options.version = normalizeText(value);
      if (token === '--channel') options.channel = normalizeText(value).toLowerCase();
      if (token === '--publish') options.publish = parseBoolean(value, '--publish');
      if (token === '--registry-url') options.registryUrl = normalizeText(value);
      if (token === '--repo') options.repository = normalizeText(value);
      if (token === '--owner') options.owner = normalizeText(value);
      if (token === '--server-url') options.serverUrl = normalizeText(value);
      if (token === '--report') options.reportPath = normalizeText(value);
      if (token === '--github-output') options.githubOutputPath = normalizeText(value);
      if (token === '--staging-dir') options.stagingDir = normalizeText(value);
      if (token === '--tarball-dir') options.tarballDir = normalizeText(value);
      if (token === '--copy-license-from') options.copyLicenseFrom = normalizeText(value);
      if (token === '--source-spec') options.sourceSpec = normalizeText(value);
      if (token === '--consumer-dir') options.consumerDir = normalizeText(value);
      if (token === '--token') options.token = normalizeText(value);
      if (token === '--install-retries') options.installRetries = parseInteger(value, { label: '--install-retries', minimum: 1 });
      if (token === '--retry-delay-ms') options.retryDelayMs = parseInteger(value, { label: '--retry-delay-ms', minimum: 0 });
      continue;
    }

    throw new Error(`Unknown option: ${token}`);
  }

  if (options.action && !ACTIONS.has(options.action)) {
    throw new Error(`Unsupported --action '${options.action}'.`);
  }

  return options;
}

export async function resolveJsPackageReleaseContext(options = {}, deps = {}) {
  const repoRoot = deps.repoRoot ?? resolveRepoRoot();
  const packageDir = resolvePath(repoRoot, options.packageDir);
  if (!packageDir) {
    throw new Error('--package-dir is required.');
  }

  const packageJsonPath = path.join(packageDir, 'package.json');
  const sourcePackageJson = await readJson(packageJsonPath);
  const packageName = trimToNull(sourcePackageJson?.name);
  if (!packageName) {
    throw new Error(`Package name is missing in ${packageJsonPath}.`);
  }

  const version = trimToNull(options.version);
  if (!version) {
    throw new Error('--version is required.');
  }

  const channel = inferChannel(version, options.channel);
  validateVersion(version, channel);

  const registryUrl = trimToNull(options.registryUrl) ?? DEFAULT_REGISTRY_URL;
  const repository = trimToNull(options.repository);
  if (!repository) {
    throw new Error('--repo is required.');
  }

  const owner = resolveOwner(options);
  const parsedName = parsePackageName(packageName);
  const expectedExports = deriveExportSpecifiers(packageName, sourcePackageJson);
  const publishEntries = await resolvePackagePublishEntries(packageDir, sourcePackageJson);
  const publishCapable = normalizeText(owner).toLowerCase() === parsedName.scopeOwner.toLowerCase();
  if (options.publish && !publishCapable) {
    throw new Error(
      `Publish rehearsal for ${packageName} requires repository owner '${parsedName.scopeOwner}', received '${owner ?? 'unknown'}'.`
    );
  }

  return {
    schema: REPORT_SCHEMA,
    action: 'resolve',
    status: 'pass',
    generatedAt: formatNow(deps.now),
    package: {
      name: packageName,
      version,
      channel,
      publish: Boolean(options.publish),
      publishCapable,
      distTag: defaultDistTag(channel),
      registryUrl,
      packageDir,
      packageSpec: formatPackageSpec(packageName, version),
      scope: parsedName.scope,
      expectedExports
    },
    repository: {
      slug: repository,
      owner: owner ?? null,
      serverUrl: trimToNull(options.serverUrl) ?? 'https://github.com'
    },
    source: {
      packageJsonPath,
      private: sourcePackageJson.private === true,
      publishEntries
    },
    outputs: {
      stagingDir: null,
      tarballPath: null,
      consumerDir: null,
      verificationMode: null
    },
    execution: {
      packCommand: null,
      installCommand: null,
      importCommand: null,
      installAttempts: 0
    }
  };
}

function writeGithubOutput(githubOutputPath, values) {
  const resolvedPath = trimToNull(githubOutputPath);
  if (!resolvedPath) {
    return;
  }

  const lines = [];
  for (const [key, value] of Object.entries(values)) {
    if (Array.isArray(value)) {
      lines.push(`${key}<<EOF`);
      for (const entry of value) {
        lines.push(String(entry));
      }
      lines.push('EOF');
      continue;
    }
    lines.push(`${key}=${value ?? ''}`);
  }

  fs.mkdirSync(path.dirname(resolvedPath), { recursive: true });
  fs.appendFileSync(resolvedPath, `${lines.join('\n')}\n`, 'utf8');
}

function buildGithubOutputs(report, reportPath) {
  const values = {
    action: report.action,
    package_name: report.package.name,
    version: report.package.version,
    channel: report.package.channel,
    publish: report.package.publish ? 'true' : 'false',
    publish_capable: report.package.publishCapable ? 'true' : 'false',
    dist_tag: report.package.distTag,
    registry_url: report.package.registryUrl,
    package_spec: report.package.packageSpec,
    expected_exports: report.package.expectedExports,
    report_path: reportPath
  };

  if (report.outputs.stagingDir) {
    values.staging_dir = report.outputs.stagingDir;
  }
  if (report.outputs.tarballPath) {
    values.tarball_path = report.outputs.tarballPath;
  }
  if (report.outputs.consumerDir) {
    values.consumer_dir = report.outputs.consumerDir;
  }
  if (report.outputs.verificationMode) {
    values.verification_mode = report.outputs.verificationMode;
  }
  if (report.source?.stagedPackageJsonPath) {
    values.staged_package_json = report.source.stagedPackageJsonPath;
  }
  return values;
}

export async function stageJsPackageRelease(options = {}, deps = {}) {
  const context = await resolveJsPackageReleaseContext(options, deps);
  const repoRoot = deps.repoRoot ?? resolveRepoRoot();
  const stagingDirInput = resolvePath(repoRoot, options.stagingDir);
  const tarballDirInput = resolvePath(repoRoot, options.tarballDir);
  if (!stagingDirInput) {
    throw new Error('--staging-dir is required for --action stage.');
  }
  if (!tarballDirInput) {
    throw new Error('--tarball-dir is required for --action stage.');
  }
  const allowedRoots = resolveManagedDirectoryRoots(repoRoot);
  const stagingDir = assertSafeManagedDirectory(stagingDirInput, {
    label: '--staging-dir',
    allowedRoots,
    repoRoot
  });
  const tarballDir = assertSafeManagedDirectory(tarballDirInput, {
    label: '--tarball-dir',
    allowedRoots,
    repoRoot
  });

  await rm(stagingDir, { recursive: true, force: true });
  await rm(tarballDir, { recursive: true, force: true });
  await mkdir(stagingDir, { recursive: true });
  await mkdir(tarballDir, { recursive: true });

  const copyPlan = createCopyPlan(context.package.packageDir, context.source.publishEntries);
  const copiedFiles = await copyPlanEntries(context.package.packageDir, stagingDir, copyPlan);
  const licensePath = await ensureLicenseFile({
    packageDir: context.package.packageDir,
    stagingDir,
    copyLicenseFrom: options.copyLicenseFrom
  });
  if (licensePath) {
    copiedFiles.push(path.basename(licensePath));
  }

  const sourcePackageJson = await readJson(context.source.packageJsonPath);
  const stagedPackageJson = buildStagedPackageJson(sourcePackageJson, {
    version: context.package.version,
    registryUrl: context.package.registryUrl,
    repository: context.repository.slug,
    serverUrl: context.repository.serverUrl
  }, [...context.source.publishEntries, ...(licensePath ? ['LICENSE'] : [])]);
  const stagedPackageJsonPath = path.join(stagingDir, 'package.json');
  await writeJson(stagedPackageJsonPath, stagedPackageJson);

  const npmPack = await (deps.runNpmFn ?? runNpmCommand)(
    ['pack', '--json', '--ignore-scripts', '--pack-destination', tarballDir],
    {
      cwd: stagingDir
    }
  );
  const packPayload = JSON.parse(npmPack.stdout.trim());
  const packEntry = Array.isArray(packPayload) ? packPayload.at(-1) : packPayload;
  const tarballPath = path.join(tarballDir, packEntry.filename);

  const report = {
    ...context,
    action: 'stage',
    outputs: {
      stagingDir,
      tarballPath,
      consumerDir: null,
      verificationMode: null
    },
    source: {
      ...context.source,
      stagedPackageJsonPath,
      copiedFiles: unique(copiedFiles)
    },
    execution: {
      packCommand: npmPack.displayCommand,
      installCommand: null,
      importCommand: null,
      installAttempts: 0
    },
    pack: {
      filename: packEntry.filename,
      unpackedSize: packEntry.unpackedSize ?? null,
      shasum: packEntry.shasum ?? null,
      integrity: packEntry.integrity ?? null
    }
  };

  return report;
}

async function installPackageCandidate({
  consumerDir,
  sourceSpec,
  context,
  token,
  installRetries,
  retryDelayMs,
  runNpmFn
}) {
  const installArgs = ['install', '--ignore-scripts', '--no-package-lock', sourceSpec];
  let npmrcPath = null;
  const npmEnv = {};
  let installOutcome = null;
  let terminalError = null;

  if (detectSourceMode(sourceSpec) === 'registry') {
    if (!token) {
      throw new Error('Registry verification requires --token or NODE_AUTH_TOKEN.');
    }
    npmrcPath = path.join(consumerDir, '.npmrc');
    await writeFile(
      npmrcPath,
      `${buildScopedNpmrc({
        scope: context.package.scope,
        registryUrl: context.package.registryUrl,
        token
      })}\n`,
      'utf8'
    );
    npmEnv.NPM_CONFIG_USERCONFIG = npmrcPath;
  }

  let lastError = null;
  let attempts = 0;
  try {
    for (attempts = 1; attempts <= installRetries; attempts += 1) {
      try {
        const result = await runNpmFn(installArgs, { cwd: consumerDir, env: npmEnv });
        installOutcome = {
          attempts,
          npmrcPath,
          result
        };
        return installOutcome;
      } catch (error) {
        lastError = error;
        if (attempts < installRetries) {
          await sleep(retryDelayMs);
        }
      }
    }

    terminalError = Object.assign(lastError ?? new Error('Install failed.'), { installAttempts: attempts, npmrcPath });
    throw terminalError;
  } finally {
    if (npmrcPath) {
      await rm(npmrcPath, { force: true });
      if (installOutcome) {
        installOutcome.npmrcPath = null;
      }
      if (terminalError) {
        terminalError.npmrcPath = null;
      }
    }
  }
}

export async function verifyJsPackageRelease(options = {}, deps = {}) {
  const context = await resolveJsPackageReleaseContext(options, deps);
  const repoRoot = deps.repoRoot ?? resolveRepoRoot();
  const consumerDirInput = resolvePath(repoRoot, options.consumerDir);
  const sourceSpec = trimToNull(options.sourceSpec);
  if (!consumerDirInput) {
    throw new Error('--consumer-dir is required for --action verify.');
  }
  if (!sourceSpec) {
    throw new Error('--source-spec is required for --action verify.');
  }
  const consumerDir = assertSafeManagedDirectory(consumerDirInput, {
    label: '--consumer-dir',
    allowedRoots: resolveManagedDirectoryRoots(repoRoot),
    repoRoot
  });

  await rm(consumerDir, { recursive: true, force: true });
  await mkdir(consumerDir, { recursive: true });
  await writeJson(path.join(consumerDir, 'package.json'), {
    name: 'runtime-harness-consumer',
    private: true,
    type: 'module'
  });

  const installOutcome = await installPackageCandidate({
    consumerDir,
    sourceSpec,
    context,
    token: trimToNull(options.token),
    installRetries: options.installRetries ?? 3,
    retryDelayMs: options.retryDelayMs ?? 5000,
    runNpmFn: deps.runNpmFn ?? runNpmCommand
  });

  const installMode = detectSourceMode(sourceSpec);
  const installedPackageJsonPath = path.join(consumerDir, 'node_modules', ...context.package.name.split('/'), 'package.json');
  const importProbe = await (deps.runNodeFn ?? runNodeEval)(
    [
      "import fs from 'node:fs';",
      'const packageName = process.env.RUNTIME_PACKAGE_NAME;',
      "const installedPackageJsonPath = process.env.RUNTIME_PACKAGE_JSON_PATH;",
      "const exportSpecifiers = JSON.parse(process.env.RUNTIME_PACKAGE_EXPORTS_JSON || '[]');",
      "const packageJson = JSON.parse(fs.readFileSync(installedPackageJsonPath, 'utf8'));",
      'const imports = [];',
      'for (const specifier of exportSpecifiers) {',
      '  const mod = await import(specifier);',
      '  imports.push({ specifier, exportKeys: Object.keys(mod).sort() });',
      '}',
      'console.log(JSON.stringify({ version: packageJson.version, imports }, null, 2));'
    ].join('\n'),
    {
      cwd: consumerDir,
      env: {
        ...process.env,
        RUNTIME_PACKAGE_NAME: context.package.name,
        RUNTIME_PACKAGE_JSON_PATH: installedPackageJsonPath,
        RUNTIME_PACKAGE_EXPORTS_JSON: JSON.stringify(context.package.expectedExports)
      }
    }
  );
  const importPayload = JSON.parse(importProbe.stdout.trim());

  return {
    ...context,
    action: 'verify',
    outputs: {
      stagingDir: null,
      tarballPath: installMode === 'tarball' ? sourceSpec : null,
      consumerDir,
      verificationMode: installMode
    },
    verification: {
      sourceSpec,
      installMode,
      installedVersion: importPayload.version,
      npmrcPath: installOutcome.npmrcPath,
      imports: importPayload.imports
    },
    execution: {
      packCommand: null,
      installCommand: installOutcome.result.displayCommand,
      importCommand: `${process.execPath} --input-type=module --eval <import-probe>`,
      installAttempts: installOutcome.attempts
    }
  };
}

export async function runJsPackageRelease(options = {}, deps = {}) {
  const action = options.action;
  if (action === 'resolve') {
    return resolveJsPackageReleaseContext(options, deps);
  }
  if (action === 'stage') {
    return stageJsPackageRelease(options, deps);
  }
  if (action === 'verify') {
    return verifyJsPackageRelease(options, deps);
  }
  throw new Error(`Unsupported action '${action}'.`);
}

export async function runCli(argv = process.argv, deps = {}) {
  const options = parseArgs(argv);
  if (options.help || !options.action) {
    printUsage();
    return 0;
  }

  const report = await runJsPackageRelease(options, deps);
  const repoRoot = deps.repoRoot ?? resolveRepoRoot();
  const reportPath = resolvePath(repoRoot, options.reportPath) ?? path.join(repoRoot, DEFAULT_REPORT_PATH);
  await writeJson(reportPath, report);
  writeGithubOutput(options.githubOutputPath, buildGithubOutputs(report, reportPath));
  process.stdout.write(`${JSON.stringify(report, null, 2)}\n`);
  return 0;
}

export function isDirectExecution(scriptPath, moduleUrl = import.meta.url) {
  const normalizedScriptPath = trimToNull(scriptPath);
  if (!normalizedScriptPath) {
    return false;
  }
  return path.resolve(normalizedScriptPath) === path.resolve(fileURLToPath(moduleUrl));
}

export const __test = {
  assertSafeManagedDirectory,
  buildScopedNpmrc,
  createCopyPlan,
  defaultDistTag,
  detectSourceMode,
  looksLikeRegistryPackageSpec,
  normalizePackageRelativePath,
  deriveExportSpecifiers,
  parsePackageName,
  resolveManagedDirectoryRoots,
  validateVersion
};

if (isDirectExecution(process.argv[1])) {
  try {
    const exitCode = await runCli(process.argv);
    process.exit(exitCode);
  } catch (error) {
    console.error(error instanceof Error ? error.message : String(error));
    process.exit(1);
  }
}

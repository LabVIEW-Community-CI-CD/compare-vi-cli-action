#!/usr/bin/env node

import fs from 'node:fs';
import path from 'node:path';
import process from 'node:process';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

export const REPORT_SCHEMA = 'priority/release-published-bundle-observer-report@v1';
export const DEFAULT_OUTPUT_PATH = path.join(
  'tests',
  'results',
  '_agent',
  'release',
  'release-published-bundle-observer.json'
);
export const DEFAULT_RESULTS_DIR = path.join(
  'tests',
  'results',
  '_agent',
  'release',
  'published-bundle-observer'
);
export const COMPAREVI_TOOLS_ASSET_PATTERN = /^CompareVI\.Tools-v.+\.zip$/i;

function asOptional(value) {
  if (value == null) {
    return null;
  }
  const normalized = String(value).trim();
  return normalized.length > 0 ? normalized : null;
}

function parseRemoteUrl(url) {
  if (!url) {
    return null;
  }
  const ssh = String(url).match(/:(?<repoPath>[^/]+\/[^/]+?)(?:\.git)?$/);
  const https = String(url).match(/github\.com\/(?<repoPath>[^/]+\/[^/]+?)(?:\.git)?$/);
  const repoPath = ssh?.groups?.repoPath ?? https?.groups?.repoPath;
  if (!repoPath) {
    return null;
  }
  const [owner, repoRaw] = repoPath.split('/');
  if (!owner || !repoRaw) {
    return null;
  }
  const repo = repoRaw.endsWith('.git') ? repoRaw.slice(0, -4) : repoRaw;
  return `${owner}/${repo}`;
}

function resolveRepositorySlug(repoRoot, explicitRepo, environment = process.env) {
  const explicit = asOptional(explicitRepo);
  if (explicit && explicit.includes('/')) {
    return explicit;
  }
  const envRepo = asOptional(environment.GITHUB_REPOSITORY);
  if (envRepo && envRepo.includes('/')) {
    return envRepo;
  }
  for (const remoteName of ['upstream', 'origin']) {
    const result = spawnSync('git', ['config', '--get', `remote.${remoteName}.url`], {
      cwd: repoRoot,
      encoding: 'utf8',
      stdio: ['ignore', 'pipe', 'ignore']
    });
    if (result.status !== 0) {
      continue;
    }
    const parsed = parseRemoteUrl(result.stdout.trim());
    if (parsed) {
      return parsed;
    }
  }
  throw new Error('Unable to resolve repository slug. Set GITHUB_REPOSITORY or pass --repo.');
}

function writeJson(filePath, payload) {
  const resolved = path.resolve(filePath);
  fs.mkdirSync(path.dirname(resolved), { recursive: true });
  fs.writeFileSync(resolved, `${JSON.stringify(payload, null, 2)}\n`, 'utf8');
  return resolved;
}

function runGhJson(args, { cwd } = {}) {
  const result = spawnSync('gh', args, {
    cwd,
    encoding: 'utf8',
    stdio: ['ignore', 'pipe', 'pipe']
  });
  if (result.status !== 0) {
    const message = result.stderr?.trim() || result.stdout?.trim() || `gh ${args.join(' ')} failed (${result.status})`;
    throw new Error(message);
  }
  const text = String(result.stdout ?? '').trim();
  return text ? JSON.parse(text) : null;
}

function runGh(args, { cwd } = {}) {
  const result = spawnSync('gh', args, {
    cwd,
    encoding: 'utf8',
    stdio: ['ignore', 'pipe', 'pipe']
  });
  if (result.status !== 0) {
    const message = result.stderr?.trim() || result.stdout?.trim() || `gh ${args.join(' ')} failed (${result.status})`;
    throw new Error(message);
  }
  return result;
}

function expandArchive(archivePath, destinationPath) {
  const archive = path.resolve(archivePath).replace(/'/g, "''");
  const destination = path.resolve(destinationPath).replace(/'/g, "''");
  const command = [
    "$ErrorActionPreference='Stop'",
    `if (Test-Path -LiteralPath '${destination}') { Remove-Item -LiteralPath '${destination}' -Recurse -Force }`,
    `Expand-Archive -LiteralPath '${archive}' -DestinationPath '${destination}' -Force`
  ].join('; ');
  const result = spawnSync('pwsh', ['-NoLogo', '-NoProfile', '-Command', command], {
    encoding: 'utf8',
    stdio: ['ignore', 'pipe', 'pipe']
  });
  if (result.status !== 0) {
    const message =
      result.stderr?.trim() || result.stdout?.trim() || `Expand-Archive failed for ${path.basename(archivePath)} (${result.status})`;
    throw new Error(message);
  }
  const directories = fs
    .readdirSync(destinationPath, { withFileTypes: true })
    .filter((entry) => entry.isDirectory())
    .map((entry) => path.join(destinationPath, entry.name));
  if (directories.length === 1) {
    return directories[0];
  }
  return destinationPath;
}

function getObjectPathValue(inputObject, objectPath) {
  const segments = String(objectPath ?? '')
    .split('.')
    .map((segment) => segment.trim())
    .filter(Boolean);
  let current = inputObject;
  for (const segment of segments) {
    if (current == null || typeof current !== 'object' || !(segment in current)) {
      return null;
    }
    current = current[segment];
  }
  return current;
}

function findCompareVIToolsAsset(release) {
  const assets = Array.isArray(release?.assets) ? release.assets : [];
  return assets.find((asset) => COMPAREVI_TOOLS_ASSET_PATTERN.test(String(asset?.name ?? ''))) ?? null;
}

function selectRelease(releases, requestedTag = null) {
  const normalizedReleases = Array.isArray(releases) ? releases : [];
  if (requestedTag) {
    const release = normalizedReleases.find((entry) => asOptional(entry?.tag_name) === requestedTag) ?? null;
    return {
      status: release ? (findCompareVIToolsAsset(release) ? 'selected' : 'asset-missing') : 'release-not-found',
      release,
      asset: release ? findCompareVIToolsAsset(release) : null
    };
  }

  for (const release of normalizedReleases) {
    const asset = findCompareVIToolsAsset(release);
    if (asset) {
      return {
        status: 'selected',
        release,
        asset
      };
    }
  }

  return {
    status: normalizedReleases.length > 0 ? 'asset-missing' : 'release-unobserved',
    release: normalizedReleases[0] ?? null,
    asset: null
  };
}

function evaluateBundleContract(bundleRoot) {
  const metadataPath = path.join(bundleRoot, 'comparevi-tools-release.json');
  const result = {
    status: 'metadata-missing',
    metadataPath,
    schema: null,
    authoritativeConsumerPin: null,
    authoritativeConsumerPinKind: null,
    capabilityId: null,
    distributionRole: null,
    distributionModel: null,
    bundleImportPath: null,
    bundleImportPathExists: false,
    releaseAssetPattern: null,
    contractPathResolutions: [],
    metadataPresent: false,
    metadataSchemaMatches: false,
    viHistoryCapabilityPresent: false,
    viHistoryCapabilityProducerNative: false,
    bundleContractPinResolved: false,
    bundleContractPathsResolved: false
  };

  if (!fs.existsSync(metadataPath)) {
    return result;
  }

  const metadata = JSON.parse(fs.readFileSync(metadataPath, 'utf8'));
  result.metadataPresent = true;
  result.schema = asOptional(metadata?.schema);
  result.metadataSchemaMatches = result.schema === 'comparevi-tools-release-manifest@v1';
  result.authoritativeConsumerPin = asOptional(metadata?.versionContract?.authoritativeConsumerPin);
  result.authoritativeConsumerPinKind = asOptional(metadata?.versionContract?.authoritativeConsumerPinKind);
  result.bundleContractPinResolved = Boolean(result.authoritativeConsumerPin && result.authoritativeConsumerPinKind);

  const capability = metadata?.consumerContract?.capabilities?.viHistory ?? null;
  result.capabilityId = asOptional(capability?.capabilityId);
  result.distributionRole = asOptional(capability?.distributionRole);
  result.distributionModel = asOptional(capability?.distributionModel);
  result.bundleImportPath = asOptional(capability?.bundleImportPath);
  result.releaseAssetPattern = asOptional(capability?.releaseAssetPattern);
  result.viHistoryCapabilityPresent =
    asOptional(capability?.schema) === 'comparevi-tools/vi-history-capability@v1' && result.capabilityId === 'vi-history';
  result.viHistoryCapabilityProducerNative =
    result.distributionRole === 'upstream-producer' && result.distributionModel === 'release-bundle';

  if (result.bundleImportPath) {
    result.bundleImportPathExists = fs.existsSync(path.join(bundleRoot, result.bundleImportPath));
  }

  const contractPaths = capability && typeof capability.contractPaths === 'object' ? capability.contractPaths : {};
  result.contractPathResolutions = Object.entries(contractPaths).map(([name, contractPath]) => ({
    name,
    path: String(contractPath),
    resolved: getObjectPathValue(metadata, contractPath) != null
  }));
  result.bundleContractPathsResolved = result.contractPathResolutions.every((entry) => entry.resolved);

  result.status =
    result.metadataSchemaMatches &&
    result.viHistoryCapabilityPresent &&
    result.viHistoryCapabilityProducerNative &&
    result.bundleContractPinResolved &&
    result.bundleImportPathExists &&
    result.bundleContractPathsResolved
      ? 'producer-native-ready'
      : 'producer-native-incomplete';

  return result;
}

function defaultDownloadAsset({ repoRoot, repository, releaseTag, assetName, destinationDirectory, runGhFn = runGh }) {
  fs.mkdirSync(destinationDirectory, { recursive: true });
  runGhFn(
    ['release', 'download', releaseTag, '--repo', repository, '--pattern', assetName, '--dir', destinationDirectory, '--clobber'],
    { cwd: repoRoot }
  );
  return path.join(destinationDirectory, assetName);
}

export function parseArgs(argv = process.argv) {
  const args = argv.slice(2);
  const options = {
    repoRoot: process.cwd(),
    repo: null,
    tag: null,
    outputPath: DEFAULT_OUTPUT_PATH,
    resultsDir: DEFAULT_RESULTS_DIR,
    help: false
  };

  for (let index = 0; index < args.length; index += 1) {
    const token = args[index];
    if (token === '-h' || token === '--help') {
      options.help = true;
      continue;
    }
    if (token === '--repo-root' || token === '--repo' || token === '--tag' || token === '--output' || token === '--results-dir') {
      const next = args[index + 1];
      if (!next || next.startsWith('-')) {
        throw new Error(`Missing value for ${token}.`);
      }
      if (token === '--repo-root') options.repoRoot = next;
      if (token === '--repo') options.repo = next;
      if (token === '--tag') options.tag = next;
      if (token === '--output') options.outputPath = next;
      if (token === '--results-dir') options.resultsDir = next;
      index += 1;
      continue;
    }
    throw new Error(`Unknown option: ${token}`);
  }

  return options;
}

function printHelp() {
  [
    'Usage: node tools/priority/release-published-bundle-observer.mjs [options]',
    '',
    'Options:',
    '  --repo-root <path>   Repository root override.',
    '  --repo <owner/repo>  Repository slug override.',
    '  --tag <tag>          Observe a specific published release tag instead of the newest CompareVI.Tools asset release.',
    `  --output <path>      Output JSON path (default: ${DEFAULT_OUTPUT_PATH}).`,
    `  --results-dir <path> Working directory for downloaded/extracted bundle files (default: ${DEFAULT_RESULTS_DIR}).`,
    '  -h, --help           Show help.'
  ].forEach((line) => console.log(line));
}

export async function runReleasePublishedBundleObserver(options = {}, deps = {}) {
  const repoRoot = path.resolve(options.repoRoot ?? process.cwd());
  const environment = deps.environment ?? process.env;
  const repository = resolveRepositorySlug(repoRoot, options.repo, environment);
  const outputPath = path.resolve(repoRoot, options.outputPath ?? DEFAULT_OUTPUT_PATH);
  const resultsDir = path.resolve(repoRoot, options.resultsDir ?? DEFAULT_RESULTS_DIR);
  const requestedTag = asOptional(options.tag);
  const runGhJsonFn = deps.runGhJsonFn ?? runGhJson;
  const downloadAssetFn = deps.downloadAssetFn ?? defaultDownloadAsset;
  const extractArchiveFn = deps.extractArchiveFn ?? expandArchive;
  const writeJsonFn = deps.writeJsonFn ?? writeJson;
  const now = deps.now ?? new Date();

  const releases = runGhJsonFn(['api', `repos/${repository}/releases?per_page=20`], { cwd: repoRoot });
  const selection = selectRelease(releases, requestedTag);

  const report = {
    schema: REPORT_SCHEMA,
    generatedAt: now.toISOString(),
    repository,
    inputs: {
      requestedTag,
      resultsDir: path.relative(repoRoot, resultsDir).replace(/\\/g, '/')
    },
    selection: {
      status: selection.status,
      releaseTag: asOptional(selection.release?.tag_name),
      publishedAt: asOptional(selection.release?.published_at),
      releaseName: asOptional(selection.release?.name),
      releaseId: selection.release?.id ?? null,
      prerelease: selection.release?.prerelease ?? null,
      draft: selection.release?.draft ?? null,
      assetName: asOptional(selection.asset?.name),
      assetId: selection.asset?.id ?? null
    },
    bundle: {
      status: 'not-downloaded',
      archivePath: null,
      extractionRoot: null,
      downloadDirectory: path.relative(repoRoot, path.join(resultsDir, 'download')).replace(/\\/g, '/')
    },
    bundleContract: {
      status: selection.status === 'release-unobserved' || selection.status === 'release-not-found' ? 'release-unobserved' : 'unobserved',
      metadataPath: null,
      schema: null,
      authoritativeConsumerPin: null,
      authoritativeConsumerPinKind: null,
      capabilityId: null,
      distributionRole: null,
      distributionModel: null,
      bundleImportPath: null,
      bundleImportPathExists: false,
      releaseAssetPattern: null,
      contractPathResolutions: [],
      metadataPresent: false,
      metadataSchemaMatches: false,
      viHistoryCapabilityPresent: false,
      viHistoryCapabilityProducerNative: false,
      bundleContractPinResolved: false,
      bundleContractPathsResolved: false
    },
    summary: {
      status: selection.status,
      releaseTag: asOptional(selection.release?.tag_name),
      assetName: asOptional(selection.asset?.name),
      publishedAt: asOptional(selection.release?.published_at),
      authoritativeConsumerPin: null
    }
  };

  if (selection.status !== 'selected') {
    const writtenPath = writeJsonFn(outputPath, report);
    return {
      report,
      outputPath: writtenPath,
      exitCode: 1
    };
  }

  const downloadDirectory = path.join(resultsDir, 'download');
  const extractDirectory = path.join(resultsDir, 'bundle');
  try {
    const archivePath = path.resolve(
      downloadAssetFn({
        repoRoot,
        repository,
        releaseTag: selection.release.tag_name,
        assetName: selection.asset.name,
        destinationDirectory: downloadDirectory,
        runGhFn: deps.runGhFn ?? runGh
      })
    );
    report.bundle.status = 'downloaded';
    report.bundle.archivePath = path.relative(repoRoot, archivePath).replace(/\\/g, '/');

    const extractionRoot = path.resolve(extractArchiveFn(archivePath, extractDirectory));
    report.bundle.status = 'extracted';
    report.bundle.extractionRoot = path.relative(repoRoot, extractionRoot).replace(/\\/g, '/');

    const bundleContract = evaluateBundleContract(extractionRoot);
    report.bundleContract = {
      ...bundleContract,
      metadataPath: path.relative(repoRoot, bundleContract.metadataPath).replace(/\\/g, '/')
    };
    report.summary.status = bundleContract.status;
    report.summary.authoritativeConsumerPin = bundleContract.authoritativeConsumerPin;
  } catch (error) {
    const message = error?.message ?? String(error);
    report.bundle.status = report.bundle.status === 'not-downloaded' ? 'download-failed' : 'extract-failed';
    report.bundle.error = message;
    report.bundleContract.status = report.bundle.status;
    report.summary.status = report.bundle.status;
  }

  const writtenPath = writeJsonFn(outputPath, report);
  return {
    report,
    outputPath: writtenPath,
    exitCode: report.summary.status === 'producer-native-ready' ? 0 : 1
  };
}

export async function main(argv = process.argv) {
  const options = parseArgs(argv);
  if (options.help) {
    printHelp();
    return 0;
  }
  const { report, outputPath, exitCode } = await runReleasePublishedBundleObserver(options);
  console.log(
    `[release-published-bundle-observer] wrote ${outputPath} status=${report.summary.status} tag=${report.summary.releaseTag ?? 'none'}`
  );
  return exitCode;
}

const isDirectExecution =
  process.argv[1] && path.resolve(process.argv[1]) === path.resolve(fileURLToPath(import.meta.url));

if (isDirectExecution) {
  main().then(
    (code) => {
      process.exitCode = code;
    },
    (error) => {
      console.error(`[release-published-bundle-observer] ${error.message}`);
      process.exitCode = 1;
    }
  );
}
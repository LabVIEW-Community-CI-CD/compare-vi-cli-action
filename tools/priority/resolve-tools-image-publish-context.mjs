#!/usr/bin/env node

import fs from 'node:fs';
import path from 'node:path';
import process from 'node:process';

export const STABLE_SEMVER_PATTERN = /^\d+\.\d+\.\d+$/;
export const STABLE_TOOLS_PATTERN = /^(\d+\.\d+\.\d+)-tools\.(\d+)$/;
export const RC_SEMVER_PATTERN = /^\d+\.\d+\.\d+-rc\.\d+$/;

const USAGE_LINES = [
  'Usage: node tools/priority/resolve-tools-image-publish-context.mjs [options]',
  '',
  'Resolve comparevi-tools image publish context from workflow inputs and release tags.',
  '',
  'Options:',
  '  --version <value>          Explicit version input.',
  '  --channel <stable|rc>      Explicit channel override.',
  '  --tag <value>              Legacy tag input.',
  '  --release-tag <value>      Release event tag.',
  '  --ref-name <value>         Ref name fallback.',
  '  --sha <value>              Git SHA for sha-* tag.',
  '  --owner <value>            Repository owner.',
  '  --repo <owner/repo>        Repository slug.',
  '  --server-url <value>       GitHub server URL.',
  '  --image-name <value>       Explicit image name override.',
  '  --github-output <path>     Write GitHub Action outputs to this file.',
  '  --tags-file <path>         Write resolved tags to this file.',
  '  --labels-file <path>       Write OCI labels to this file.',
  '  -h, --help                 Show this message and exit.'
];

function printUsage() {
  for (const line of USAGE_LINES) {
    console.log(line);
  }
}

function readOptionValue(args, index, token) {
  const next = args[index + 1];
  if (typeof next === 'undefined' || (next.startsWith('-') && next.length > 0)) {
    throw new Error(`Missing value for ${token}.`);
  }
  return next;
}

function trimToNull(value) {
  const normalized = String(value ?? '').trim();
  return normalized.length > 0 ? normalized : null;
}

export function parseArgs(argv = process.argv) {
  const args = argv.slice(2);
  const options = {
    version: null,
    channel: null,
    tag: null,
    releaseTag: null,
    refName: null,
    sha: trimToNull(process.env.GITHUB_SHA),
    owner: trimToNull(process.env.REPOSITORY_OWNER ?? process.env.GITHUB_REPOSITORY_OWNER),
    repository: trimToNull(process.env.GITHUB_REPOSITORY),
    serverUrl: trimToNull(process.env.GITHUB_SERVER_URL),
    imageName: null,
    githubOutputPath: trimToNull(process.env.GITHUB_OUTPUT),
    tagsFilePath: null,
    labelsFilePath: null,
    help: false
  };

  for (let index = 0; index < args.length; index += 1) {
    const token = args[index];
    if (token === '-h' || token === '--help') {
      options.help = true;
      continue;
    }

    if (
      token === '--version' ||
      token === '--channel' ||
      token === '--tag' ||
      token === '--release-tag' ||
      token === '--ref-name' ||
      token === '--sha' ||
      token === '--owner' ||
      token === '--repo' ||
      token === '--server-url' ||
      token === '--image-name' ||
      token === '--github-output' ||
      token === '--tags-file' ||
      token === '--labels-file'
    ) {
      const value = readOptionValue(args, index, token);
      index += 1;

      if (token === '--version') options.version = trimToNull(value);
      if (token === '--channel') options.channel = trimToNull(value);
      if (token === '--tag') options.tag = trimToNull(value);
      if (token === '--release-tag') options.releaseTag = trimToNull(value);
      if (token === '--ref-name') options.refName = trimToNull(value);
      if (token === '--sha') options.sha = trimToNull(value);
      if (token === '--owner') options.owner = trimToNull(value);
      if (token === '--repo') options.repository = trimToNull(value);
      if (token === '--server-url') options.serverUrl = trimToNull(value);
      if (token === '--image-name') options.imageName = trimToNull(value);
      if (token === '--github-output') options.githubOutputPath = trimToNull(value);
      if (token === '--tags-file') options.tagsFilePath = trimToNull(value);
      if (token === '--labels-file') options.labelsFilePath = trimToNull(value);
      continue;
    }

    throw new Error(`Unknown option: ${token}`);
  }

  return options;
}

export function normalizeRequestedVersion(rawValue) {
  let version = String(rawValue ?? '').trim();
  version = version.replace(/^comparevi-tools-v/, '');
  version = version.replace(/^shared-v/, '');
  version = version.replace(/^v/, '');
  return version.trim();
}

function deriveRawVersion(options) {
  return (
    trimToNull(options.version) ??
    trimToNull(options.tag) ??
    trimToNull(options.releaseTag) ??
    trimToNull(options.refName) ??
    ''
  );
}

function inferChannel(version, explicitChannel) {
  const channel = trimToNull(explicitChannel);
  if (channel) {
    return channel;
  }
  return version.includes('-rc.') ? 'rc' : 'stable';
}

export function parseVersionShape(version, channel) {
  if (channel === 'stable') {
    if (STABLE_SEMVER_PATTERN.test(version)) {
      return {
        stableFamilyVersion: version,
        isToolsTag: false,
        toolsIteration: null
      };
    }

    const toolsMatch = STABLE_TOOLS_PATTERN.exec(version);
    if (toolsMatch) {
      return {
        stableFamilyVersion: toolsMatch[1],
        isToolsTag: true,
        toolsIteration: Number.parseInt(toolsMatch[2], 10)
      };
    }

    throw new Error(`Stable channel requires X.Y.Z or X.Y.Z-tools.N version. Received: ${version}`);
  }

  if (channel === 'rc') {
    if (!RC_SEMVER_PATTERN.test(version)) {
      throw new Error(`RC channel requires X.Y.Z-rc.N version. Received: ${version}`);
    }

    return {
      stableFamilyVersion: null,
      isToolsTag: false,
      toolsIteration: null
    };
  }

  throw new Error(`Unsupported channel: ${channel}`);
}

function dedupePreservingOrder(values) {
  const seen = new Set();
  const result = [];
  for (const value of values) {
    if (!value || seen.has(value)) {
      continue;
    }
    seen.add(value);
    result.push(value);
  }
  return result;
}

export function buildImageTags({ imageName, version, channel, stableFamilyVersion, sha }) {
  const tags = [];
  const shortSha = trimToNull(sha)?.slice(0, 7) ?? null;
  if (shortSha) {
    tags.push(`${imageName}:sha-${shortSha}`);
  }

  tags.push(`${imageName}:comparevi-tools-v${version}`);
  tags.push(`${imageName}:v${version}`);
  tags.push(`${imageName}:${version}`);

  if (channel === 'stable') {
    const stableAlias = stableFamilyVersion ?? version;
    tags.push(`${imageName}:comparevi-tools-v${stableAlias}`);
    tags.push(`${imageName}:v${stableAlias}`);
    tags.push(`${imageName}:${stableAlias}`);

    const [major, minor] = stableAlias.split('.');
    tags.push(`${imageName}:comparevi-tools-v${major}.${minor}`);
    tags.push(`${imageName}:comparevi-tools-v${major}`);
    tags.push(`${imageName}:latest`);
  }

  return dedupePreservingOrder(tags);
}

export function buildImageLabels({ serverUrl, repository, sha, version }) {
  return [
    `org.opencontainers.image.source=${serverUrl}/${repository}`,
    `org.opencontainers.image.revision=${sha}`,
    `org.opencontainers.image.version=${version}`,
    'org.opencontainers.image.title=comparevi-tools'
  ].join('\n');
}

function resolveRepositoryOwner(owner, repository) {
  if (trimToNull(owner)) {
    return String(owner).trim().toLowerCase();
  }

  const repoSlug = trimToNull(repository);
  if (repoSlug && repoSlug.includes('/')) {
    return repoSlug.split('/')[0].toLowerCase();
  }

  throw new Error('Unable to determine repository owner.');
}

export function resolveToolsImagePublishContext(options = {}) {
  const rawVersion = deriveRawVersion(options);
  const version = normalizeRequestedVersion(rawVersion);
  if (!version) {
    throw new Error('Unable to determine version from inputs/release/ref context.');
  }

  const channel = inferChannel(version, options.channel);
  const shape = parseVersionShape(version, channel);
  const repository = trimToNull(options.repository);
  const owner = resolveRepositoryOwner(options.owner, repository);
  const imageName = trimToNull(options.imageName) ?? `ghcr.io/${owner}/comparevi-tools`;
  const serverUrl = trimToNull(options.serverUrl) ?? 'https://github.com';
  const sha = trimToNull(options.sha) ?? '';

  return {
    imageName,
    version,
    channel,
    stableFamilyVersion: shape.stableFamilyVersion,
    isToolsTag: shape.isToolsTag,
    tags: buildImageTags({
      imageName,
      version,
      channel,
      stableFamilyVersion: shape.stableFamilyVersion,
      sha
    }),
    labels: buildImageLabels({
      serverUrl,
      repository: repository ?? `${owner}/compare-vi-cli-action`,
      sha,
      version
    })
  };
}

function ensureParentDirectory(filePath) {
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
}

export function writeOutputs(context, options = {}) {
  const tagsFilePath =
    trimToNull(options.tagsFilePath) ??
    path.join(process.env.RUNNER_TEMP ?? process.cwd(), 'tools-image-tags.txt');
  const labelsFilePath =
    trimToNull(options.labelsFilePath) ??
    path.join(process.env.RUNNER_TEMP ?? process.cwd(), 'tools-image-labels.txt');

  ensureParentDirectory(tagsFilePath);
  ensureParentDirectory(labelsFilePath);
  fs.writeFileSync(tagsFilePath, `${context.tags.join('\n')}\n`, 'utf8');
  fs.writeFileSync(labelsFilePath, `${context.labels}\n`, 'utf8');

  const githubOutputPath = trimToNull(options.githubOutputPath);
  if (githubOutputPath) {
    ensureParentDirectory(githubOutputPath);
    const lines = [
      `image_name=${context.imageName}`,
      `version=${context.version}`,
      `channel=${context.channel}`,
      `stable_family_version=${context.stableFamilyVersion ?? ''}`,
      `is_tools_tag=${context.isToolsTag ? 'true' : 'false'}`,
      `tags_file=${tagsFilePath}`,
      `labels_file=${labelsFilePath}`,
      'tags<<EOF',
      ...context.tags,
      'EOF'
    ];
    fs.appendFileSync(githubOutputPath, `${lines.join('\n')}\n`, 'utf8');
  }

  return {
    ...context,
    tagsFilePath,
    labelsFilePath
  };
}

function main() {
  const options = parseArgs(process.argv);
  if (options.help) {
    printUsage();
    return;
  }

  const context = resolveToolsImagePublishContext(options);
  const result = writeOutputs(context, options);
  console.log(
    JSON.stringify(
      {
        imageName: result.imageName,
        version: result.version,
        channel: result.channel,
        stableFamilyVersion: result.stableFamilyVersion,
        isToolsTag: result.isToolsTag,
        tags: result.tags
      },
      null,
      2
    )
  );
}

if (import.meta.url === `file://${process.argv[1]}`) {
  try {
    main();
  } catch (error) {
    console.error(error instanceof Error ? error.message : String(error));
    process.exitCode = 1;
  }
}

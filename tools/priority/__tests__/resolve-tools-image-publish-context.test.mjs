import test from 'node:test';
import assert from 'node:assert/strict';
import os from 'node:os';
import path from 'node:path';
import fs from 'node:fs';
import { pathToFileURL } from 'node:url';
import {
  buildImageTags,
  isDirectExecution,
  normalizeRequestedVersion,
  parseArgs,
  parseVersionShape,
  resolveToolsImagePublishContext,
  writeOutputs
} from '../resolve-tools-image-publish-context.mjs';

test('parseArgs applies defaults and explicit values', () => {
  const defaults = parseArgs(['node', 'resolve-tools-image-publish-context.mjs']);
  assert.equal(defaults.version, null);
  assert.equal(defaults.channel, null);
  assert.equal(defaults.tag, null);
  assert.equal(defaults.releaseTag, null);
  assert.equal(defaults.githubOutputPath, process.env.GITHUB_OUTPUT ?? null);

  const parsed = parseArgs([
    'node',
    'resolve-tools-image-publish-context.mjs',
    '--version',
    '0.6.3-tools.4',
    '--channel',
    'stable',
    '--release-tag',
    'v0.6.3-tools.4',
    '--ref-name',
    'v0.6.3-tools.4',
    '--sha',
    'abcdef1234567890',
    '--owner',
    'LabVIEW-Community-CI-CD',
    '--repo',
    'LabVIEW-Community-CI-CD/compare-vi-cli-action',
    '--server-url',
    'https://github.com',
    '--github-output',
    'out.txt',
    '--tags-file',
    'tags.txt',
    '--labels-file',
    'labels.txt'
  ]);

  assert.equal(parsed.version, '0.6.3-tools.4');
  assert.equal(parsed.channel, 'stable');
  assert.equal(parsed.releaseTag, 'v0.6.3-tools.4');
  assert.equal(parsed.sha, 'abcdef1234567890');
  assert.equal(parsed.owner, 'LabVIEW-Community-CI-CD');
  assert.equal(parsed.repository, 'LabVIEW-Community-CI-CD/compare-vi-cli-action');
  assert.equal(parsed.tagsFilePath, 'tags.txt');
});

test('parseArgs treats quoted blank workflow inputs as null instead of missing', () => {
  const parsed = parseArgs([
    'node',
    'resolve-tools-image-publish-context.mjs',
    '--version',
    '',
    '--channel',
    '',
    '--tag',
    '',
    '--release-tag',
    'v0.6.3-tools.4'
  ]);

  assert.equal(parsed.version, null);
  assert.equal(parsed.channel, null);
  assert.equal(parsed.tag, null);
  assert.equal(parsed.releaseTag, 'v0.6.3-tools.4');
});

test('normalizeRequestedVersion strips supported prefixes', () => {
  assert.equal(normalizeRequestedVersion('comparevi-tools-v0.6.3-tools.4'), '0.6.3-tools.4');
  assert.equal(normalizeRequestedVersion('v0.6.3'), '0.6.3');
  assert.equal(normalizeRequestedVersion('shared-v0.2.0'), '0.2.0');
});

test('parseVersionShape accepts stable bundle tags and preserves stable family version', () => {
  const stable = parseVersionShape('0.6.3', 'stable');
  assert.equal(stable.stableFamilyVersion, '0.6.3');
  assert.equal(stable.isToolsTag, false);

  const tools = parseVersionShape('0.6.3-tools.4', 'stable');
  assert.equal(tools.stableFamilyVersion, '0.6.3');
  assert.equal(tools.isToolsTag, true);
  assert.equal(tools.toolsIteration, 4);

  const rc = parseVersionShape('0.6.3-rc.2', 'rc');
  assert.equal(rc.stableFamilyVersion, null);
  assert.equal(rc.isToolsTag, false);
});

test('parseVersionShape rejects unsupported channel/version combinations', () => {
  assert.throws(
    () => parseVersionShape('0.6.3-tools.4', 'rc'),
    /RC channel requires X\.Y\.Z-rc\.N version/
  );
  assert.throws(
    () => parseVersionShape('0.6.3-beta.1', 'stable'),
    /Stable channel requires X\.Y\.Z or X\.Y\.Z-tools\.N version/
  );
});

test('buildImageTags emits exact bundle tag plus stable aliases for tools releases', () => {
  const tags = buildImageTags({
    imageName: 'ghcr.io/labview-community-ci-cd/comparevi-tools',
    version: '0.6.3-tools.4',
    channel: 'stable',
    stableFamilyVersion: '0.6.3',
    sha: 'abcdef1234567890'
  });

  assert.deepEqual(tags, [
    'ghcr.io/labview-community-ci-cd/comparevi-tools:sha-abcdef1',
    'ghcr.io/labview-community-ci-cd/comparevi-tools:comparevi-tools-v0.6.3-tools.4',
    'ghcr.io/labview-community-ci-cd/comparevi-tools:v0.6.3-tools.4',
    'ghcr.io/labview-community-ci-cd/comparevi-tools:0.6.3-tools.4',
    'ghcr.io/labview-community-ci-cd/comparevi-tools:comparevi-tools-v0.6.3',
    'ghcr.io/labview-community-ci-cd/comparevi-tools:v0.6.3',
    'ghcr.io/labview-community-ci-cd/comparevi-tools:0.6.3',
    'ghcr.io/labview-community-ci-cd/comparevi-tools:comparevi-tools-v0.6',
    'ghcr.io/labview-community-ci-cd/comparevi-tools:comparevi-tools-v0',
    'ghcr.io/labview-community-ci-cd/comparevi-tools:latest'
  ]);
});

test('resolveToolsImagePublishContext infers tools-tag stable publishing from release tags', () => {
  const context = resolveToolsImagePublishContext({
    releaseTag: 'v0.6.3-tools.4',
    refName: 'v0.6.3-tools.4',
    sha: 'abcdef1234567890',
    owner: 'LabVIEW-Community-CI-CD',
    repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
    serverUrl: 'https://github.com'
  });

  assert.equal(context.imageName, 'ghcr.io/labview-community-ci-cd/comparevi-tools');
  assert.equal(context.version, '0.6.3-tools.4');
  assert.equal(context.channel, 'stable');
  assert.equal(context.stableFamilyVersion, '0.6.3');
  assert.equal(context.isToolsTag, true);
  assert.match(context.labels, /org\.opencontainers\.image\.version=0\.6\.3-tools\.4/);
});

test('writeOutputs persists GitHub outputs, tag file, and label file', () => {
  const tempRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'comparevi-tools-context-'));
  const githubOutputPath = path.join(tempRoot, 'github-output.txt');
  const tagsFilePath = path.join(tempRoot, 'tags.txt');
  const labelsFilePath = path.join(tempRoot, 'labels.txt');

  const result = writeOutputs(
    {
      imageName: 'ghcr.io/labview-community-ci-cd/comparevi-tools',
      version: '0.6.3-tools.4',
      channel: 'stable',
      stableFamilyVersion: '0.6.3',
      isToolsTag: true,
      tags: ['tag-a', 'tag-b'],
      labels: 'label-a=value'
    },
    {
      githubOutputPath,
      tagsFilePath,
      labelsFilePath
    }
  );

  assert.equal(result.tagsFilePath, tagsFilePath);
  assert.equal(result.labelsFilePath, labelsFilePath);
  assert.equal(fs.readFileSync(tagsFilePath, 'utf8'), 'tag-a\ntag-b\n');
  assert.equal(fs.readFileSync(labelsFilePath, 'utf8'), 'label-a=value\n');
  const githubOutput = fs.readFileSync(githubOutputPath, 'utf8');
  assert.match(githubOutput, /version=0\.6\.3-tools\.4/);
  assert.match(githubOutput, /stable_family_version=0\.6\.3/);
  assert.match(githubOutput, /is_tools_tag=true/);
  assert.match(githubOutput, /tags<<EOF/);
});

test('isDirectExecution follows the repo standard for filesystem path comparison', () => {
  const modulePath = path.join('D:', 'workspace', 'compare-vi-cli-action', 'compare-vi-cli-action', 'tools', 'priority', 'resolve-tools-image-publish-context.mjs');
  const moduleUrl = pathToFileURL(modulePath).href;

  assert.equal(isDirectExecution(modulePath, moduleUrl), true);
  assert.equal(isDirectExecution(path.join('D:', 'workspace', 'compare-vi-cli-action', 'compare-vi-cli-action', 'tools', 'priority', 'other-script.mjs'), moduleUrl), false);
  assert.equal(isDirectExecution('', moduleUrl), false);
});

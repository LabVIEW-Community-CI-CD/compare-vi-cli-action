#!/usr/bin/env node

import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';

import {
  DEFAULT_POLICY_PATH,
  loadTemplateDependencyPolicy,
  resolveWorkspaceRoot
} from '../template-cookiecutter-container.mjs';

const repoRoot = path.resolve(process.cwd());

test('template dependency policy pins the template repository release and cookiecutter runtime', () => {
  const policy = loadTemplateDependencyPolicy(DEFAULT_POLICY_PATH);

  assert.equal(policy.schema, 'priority/template-dependency@v1');
  assert.equal(policy.schemaVersion, '1.0.0');
  assert.equal(policy.templateRepositorySlug, 'LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate');
  assert.equal(policy.templateReleaseRef, 'v0.1.0');
  assert.equal(policy.cookiecutterVersion, '2.7.1');
  assert.equal(policy.container.runtime, 'docker');
  assert.equal(policy.container.image, 'ghcr.io/labview-community-ci-cd/comparevi-tools:latest');
  assert.equal(policy.container.executionPlane, 'linux-tools-image');
  assert.equal(policy.rendering.checkout, 'v0.1.0');
  assert.equal(policy.rendering.defaultContextPath, 'tests/fixtures/cookiecutter/template-context.json');
  assert.equal(policy.rendering.deterministicInput, true);
  assert.equal(policy.rendering.noInput, true);
  assert.equal(policy.workspaceRoots.win32, 'E:\\comparevi-template-consumers');
  assert.equal(policy.workspaceRoots.posix, '/tmp/comparevi-template-consumers');
});

test('template dependency policy validates against the checked-in schema', () => {
  const schema = JSON.parse(
    fs.readFileSync(path.join(repoRoot, 'docs', 'schemas', 'template-dependency-v1.schema.json'), 'utf8')
  );

  assert.equal(schema.schema, undefined);
  assert.equal(schema.$schema, 'https://json-schema.org/draft/2020-12/schema');
  assert.equal(schema.$id, 'https://labview-community-ci-cd.github.io/compare-vi-cli-action/schemas/template-dependency-v1.schema.json');
  assert.equal(schema.properties.schema.const, 'priority/template-dependency@v1');
  assert.equal(schema.properties.templateRepositorySlug.const, 'LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate');
  assert.equal(schema.properties.templateReleaseRef.const, 'v0.1.0');
  assert.equal(schema.properties.cookiecutterVersion.const, '2.7.1');
  assert.equal(schema.properties.container.properties.runtime.const, 'docker');
  assert.equal(schema.properties.rendering.properties.checkout.const, 'v0.1.0');
  assert.equal(
    schema.properties.rendering.properties.defaultContextPath.const,
    'tests/fixtures/cookiecutter/template-context.json'
  );
  assert.equal(schema.additionalProperties, false);
});

test('workspace roots resolve by platform without mutating the pinned policy', () => {
  const policy = JSON.parse(fs.readFileSync(DEFAULT_POLICY_PATH, 'utf8'));

  assert.equal(resolveWorkspaceRoot(policy, 'win32'), 'E:\\comparevi-template-consumers');
  assert.equal(resolveWorkspaceRoot(policy, 'linux'), '/tmp/comparevi-template-consumers');
  assert.equal(
    resolveWorkspaceRoot(policy, 'win32', 'C:\\override-root'),
    'C:\\override-root'
  );
});

test('docker tools image policy stays pinned in the tools Dockerfile', () => {
  const dockerfile = fs.readFileSync(path.join(repoRoot, 'tools', 'docker', 'Dockerfile.tools'), 'utf8');

  assert.match(dockerfile, /cookiecutter==2\.7\.1/);
  assert.match(dockerfile, /--break-system-packages/);
  assert.match(dockerfile, /cookiecutter --version/);
});

#!/usr/bin/env node

import test from 'node:test';
import assert from 'node:assert/strict';
import path from 'node:path';
import { readFileSync } from 'node:fs';

const repoRoot = process.cwd();
const canonicalUpstreamSlug = 'LabVIEW-Community-CI-CD/compare-vi-cli-action';

function readRepoFile(relativePath) {
  return readFileSync(path.join(repoRoot, relativePath), 'utf8');
}

function escapeRegExp(value) {
  return value.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

test('issue-event standing-priority snapshot resolves fork context through the canonical upstream slug', () => {
  const workflow = readRepoFile('.github/workflows/issue-snapshot.yml');
  const stepPattern = new RegExp(
    [
      '- name: Sync standing-priority snapshot',
      '[\\s\\S]*?',
      `AGENT_PRIORITY_UPSTREAM_REPOSITORY: ${escapeRegExp(canonicalUpstreamSlug)}`,
      '[\\s\\S]*?',
      'node tools/npm/run-script\\.mjs priority:sync:lane'
    ].join('')
  );

  assert.match(workflow, stepPattern);
});

test('validate standing-priority snapshot resolves fork context through the canonical upstream slug', () => {
  const workflow = readRepoFile('.github/workflows/validate.yml');
  const stepPattern = new RegExp(
    [
      '- name: Sync standing-priority snapshot',
      '[\\s\\S]*?',
      `AGENT_PRIORITY_UPSTREAM_REPOSITORY: ${escapeRegExp(canonicalUpstreamSlug)}`,
      '[\\s\\S]*?',
      'node tools/npm/run-script\\.mjs priority:sync:lane'
    ].join('')
  );

  assert.match(workflow, stepPattern);
});

#!/usr/bin/env node

import test from 'node:test';
import assert from 'node:assert/strict';
import os from 'node:os';
import path from 'node:path';
import { mkdtemp, readFile } from 'node:fs/promises';
import {
  POLICY_SHADOW_FILES,
  exportPersonalForkPolicyShadow,
  parseArgs,
} from '../export-personal-fork-policy-shadow.mjs';

test('parseArgs requires repo/ref and keeps report/workspace overrides', () => {
  const options = parseArgs([
    'node',
    'tools/policy/export-personal-fork-policy-shadow.mjs',
    '--repo',
    'owner/repo',
    '--ref',
    'abc123',
    '--workspace-root',
    'shadow-root',
    '--report',
    'shadow-report.json',
  ]);

  assert.equal(options.repo, 'owner/repo');
  assert.equal(options.ref, 'abc123');
  assert.equal(options.workspaceRoot, 'shadow-root');
  assert.equal(options.report, 'shadow-report.json');
});

test('exportPersonalForkPolicyShadow overlays policy surfaces from GitHub contents', async () => {
  const workspaceRoot = await mkdtemp(path.join(os.tmpdir(), 'policy-shadow-'));
  const reportPath = path.join(workspaceRoot, 'report.json');
  const requested = [];
  const encoded = new Map(
    POLICY_SHADOW_FILES.map((relativePath) => [
      relativePath,
      {
        type: 'file',
        encoding: 'base64',
        content: Buffer.from(`shadow:${relativePath}`, 'utf8').toString('base64'),
        sha: `sha-${relativePath}`,
        size: 7,
      },
    ]),
  );

  const result = await exportPersonalForkPolicyShadow({
    repo: 'someone/compare-vi-cli-action',
    ref: 'deadbeef',
    workspaceRoot,
    report: reportPath,
    env: { GH_TOKEN: 'token-value' },
    fetchFn: async (url, options) => {
      requested.push({ url, options });
      const matched = POLICY_SHADOW_FILES.find((candidate) => url.includes(encodeURIComponent(candidate.split('/').pop())));
      const relativePath = POLICY_SHADOW_FILES.find((candidate) => url.includes(candidate.replace(/\//g, '%2F')));
      const payload = encoded.get(relativePath ?? matched);
      return {
        ok: true,
        async json() {
          return payload;
        },
      };
    },
  });

  assert.equal(result.repository, 'someone/compare-vi-cli-action');
  assert.equal(result.ref, 'deadbeef');
  assert.equal(result.files.length, POLICY_SHADOW_FILES.length);
  assert.equal(requested.length, POLICY_SHADOW_FILES.length);

  for (const relativePath of POLICY_SHADOW_FILES) {
    const absolutePath = path.join(workspaceRoot, ...relativePath.split('/'));
    const content = await readFile(absolutePath, 'utf8');
    assert.equal(content, `shadow:${relativePath}`);
  }

  const report = JSON.parse(await readFile(reportPath, 'utf8'));
  assert.equal(report.schema, 'policy/personal-fork-shadow-export@v1');
  assert.equal(report.files.length, POLICY_SHADOW_FILES.length);
});

test('exportPersonalForkPolicyShadow fails closed on unsupported payload encoding', async () => {
  await assert.rejects(
    exportPersonalForkPolicyShadow({
      repo: 'someone/compare-vi-cli-action',
      ref: 'deadbeef',
      workspaceRoot: await mkdtemp(path.join(os.tmpdir(), 'policy-shadow-fail-')),
      env: { GH_TOKEN: 'token-value' },
      fetchFn: async () => ({
        ok: true,
        async json() {
          return {
            type: 'file',
            encoding: 'utf8',
            content: 'bad',
          };
        },
      }),
    }),
    /expected base64 content/,
  );
});

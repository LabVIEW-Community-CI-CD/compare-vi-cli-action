#!/usr/bin/env node

import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  parseArgs,
  resolveRepositorySlug,
  runCanaryReplayConformance,
  stripGeneratedTimestamps
} from '../canary-replay-conformance.mjs';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..', '..');

test('parseArgs supports explicit replay inputs', () => {
  const parsed = parseArgs([
    'node',
    'canary-replay-conformance.mjs',
    '--catalog',
    'catalog.json',
    '--policy',
    'policy.json',
    '--branch-policy',
    'branch-policy.json',
    '--required-checks',
    'required-checks.json',
    '--report',
    'report.json',
    '--repo',
    'example/repo',
    '--no-strict'
  ]);

  assert.equal(parsed.catalogPath, 'catalog.json');
  assert.equal(parsed.policyPath, 'policy.json');
  assert.equal(parsed.branchPolicyPath, 'branch-policy.json');
  assert.equal(parsed.requiredChecksPath, 'required-checks.json');
  assert.equal(parsed.reportPath, 'report.json');
  assert.equal(parsed.repository, 'example/repo');
  assert.equal(parsed.strict, false);
});

test('resolveRepositorySlug uses explicit, env, then upstream/origin remote fallbacks', () => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'canary-replay-repo-'));
  const gitDir = path.join(tmpDir, '.git');
  fs.mkdirSync(gitDir, { recursive: true });
  fs.writeFileSync(
    path.join(gitDir, 'config'),
    [
      '[remote "origin"]',
      '  url = https://github.com/fork-owner/fork-repo.git',
      '[remote "upstream"]',
      '  url = git@github.com:upstream-owner/upstream-repo.git'
    ].join('\n'),
    'utf8'
  );

  assert.equal(resolveRepositorySlug(tmpDir, 'explicit-owner/explicit-repo', {}), 'explicit-owner/explicit-repo');
  assert.equal(resolveRepositorySlug(tmpDir, null, { GITHUB_REPOSITORY: 'env-owner/env-repo' }), 'env-owner/env-repo');
  assert.equal(resolveRepositorySlug(tmpDir, null, {}), 'upstream-owner/upstream-repo');

  fs.writeFileSync(
    path.join(gitDir, 'config'),
    ['[remote "origin"]', '  url = https://github.com/fork-owner/fork-repo.git'].join('\n'),
    'utf8'
  );
  assert.equal(resolveRepositorySlug(tmpDir, null, {}), 'fork-owner/fork-repo');
});

test('stripGeneratedTimestamps removes generatedAt fields recursively', () => {
  const payload = {
    generatedAt: '2026-03-07T02:00:00Z',
    nested: {
      generatedAt: '2026-03-07T02:01:00Z',
      keep: true
    },
    entries: [
      { generatedAt: '2026-03-07T02:02:00Z', value: 1 },
      { value: 2 }
    ]
  };

  const stripped = stripGeneratedTimestamps(payload);
  assert.deepEqual(stripped, {
    nested: { keep: true },
    entries: [{ value: 1 }, { value: 2 }]
  });
});

test('runCanaryReplayConformance passes for canonical catalog and policy', async () => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'canary-replay-pass-'));
  const reportPath = path.join(tmpDir, 'replay-report.json');
  const result = await runCanaryReplayConformance({
    argv: [
      'node',
      'canary-replay-conformance.mjs',
      '--catalog',
      path.join(repoRoot, 'tools', 'priority', 'canary-signal-catalog.json'),
      '--policy',
      path.join(repoRoot, 'tools', 'priority', 'issue-routing-policy.json'),
      '--branch-policy',
      path.join(repoRoot, 'tools', 'priority', 'policy.json'),
      '--required-checks',
      path.join(repoRoot, 'tools', 'policy', 'branch-required-checks.json'),
      '--report',
      reportPath,
      '--repo',
      'example/repo'
    ],
    now: new Date('2026-03-07T02:10:00Z'),
    repoRoot
  });

  assert.equal(result.exitCode, 0);
  assert.equal(result.report.status, 'pass');
  assert.equal(result.report.checks.noDuplicateIssueIntents, true);
  assert.equal(result.report.checks.byteStableDecisions, true);
  assert.equal(result.report.checks.deterministicOrdering, true);
  assert.equal(typeof result.report.checks.routeExpectationMatch, 'boolean');

  const repeated = result.report.scenarios.find((scenario) => scenario.id === 'repeated');
  assert.ok(repeated);
  assert.deepEqual(repeated.duplicateCreateFingerprints, []);
  assert.ok(repeated.operations.length > 0);
  assert.ok(repeated.decisionSnapshots.every((snapshot) => snapshot.policyDecision.schema === 'priority/policy-decision-report@v1'));

  const persisted = JSON.parse(fs.readFileSync(reportPath, 'utf8'));
  assert.equal(persisted.schema, 'priority/canary-replay-conformance-report@v1');
});

test('runCanaryReplayConformance fails strict mode when router creates duplicate issue intents', async () => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'canary-replay-fail-'));
  const reportPath = path.join(tmpDir, 'replay-report.json');
  let issueNumber = 100;
  const result = await runCanaryReplayConformance({
    argv: [
      'node',
      'canary-replay-conformance.mjs',
      '--catalog',
      path.join(repoRoot, 'tools', 'priority', 'canary-signal-catalog.json'),
      '--policy',
      path.join(repoRoot, 'tools', 'priority', 'issue-routing-policy.json'),
      '--branch-policy',
      path.join(repoRoot, 'tools', 'priority', 'policy.json'),
      '--required-checks',
      path.join(repoRoot, 'tools', 'policy', 'branch-required-checks.json'),
      '--report',
      reportPath,
      '--repo',
      'example/repo'
    ],
    now: new Date('2026-03-07T02:11:00Z'),
    repoRoot,
    runIssueRouterFn: async () => {
      const currentIssue = issueNumber;
      issueNumber += 1;
      return {
        exitCode: 0,
        report: {
          route: {
            operation: {
              action: 'create',
              issueNumber: currentIssue,
              issueUrl: `https://example.test/issues/${currentIssue}`,
              wrote: true
            },
            dedupe: {
              candidateCount: 0
            }
          }
        }
      };
    }
  });

  assert.equal(result.exitCode, 1);
  assert.equal(result.report.status, 'fail');
  assert.equal(result.report.checks.noDuplicateIssueIntents, false);
  assert.ok(result.report.scenarios.some((scenario) => scenario.duplicateCreateFingerprints.length > 0));
});

#!/usr/bin/env node

import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {
  LABEL_POLICY_SCHEMA,
  buildLabelPlan,
  normalizeLabelPolicy,
  parseArgs,
  resolveRepositorySlug,
  runBootstrapContracts
} from '../bootstrap-contracts.mjs';

test('parseArgs parses bootstrap flags', () => {
  const parsed = parseArgs([
    'node',
    'bootstrap-contracts.mjs',
    '--repo',
    'owner/repo',
    '--labels-policy',
    'labels.json',
    '--report',
    'report.json',
    '--policy-report',
    'policy.json',
    '--apply-policy',
    '--strict-policy',
    '--policy-fail-on-skip',
    '--dry-run'
  ]);

  assert.equal(parsed.repo, 'owner/repo');
  assert.equal(parsed.labelsPolicyPath, 'labels.json');
  assert.equal(parsed.reportPath, 'report.json');
  assert.equal(parsed.policyReportPath, 'policy.json');
  assert.equal(parsed.applyPolicy, true);
  assert.equal(parsed.strictPolicy, true);
  assert.equal(parsed.policyFailOnSkip, true);
  assert.equal(parsed.dryRun, true);
});

test('resolveRepositorySlug supports explicit/env/upstream/origin fallbacks', () => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'bootstrap-contracts-slug-'));
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

test('normalizeLabelPolicy validates schema and label metadata', () => {
  const normalized = normalizeLabelPolicy({
    schema: LABEL_POLICY_SCHEMA,
    schemaVersion: '1.0.0',
    labels: [
      { name: 'queue-blocked', description: 'Blocked', color: 'D93F0B' },
      { name: 'standing-priority', description: 'Primary', color: '#FFFFFF' }
    ]
  });

  assert.equal(normalized.schema, LABEL_POLICY_SCHEMA);
  assert.equal(normalized.labels.length, 2);
  assert.deepEqual(normalized.labels.map((entry) => entry.name), ['queue-blocked', 'standing-priority']);
  assert.equal(normalized.labels[1].color, 'ffffff');
});

test('buildLabelPlan creates deterministic create/update/noop actions', () => {
  const desired = [
    { name: 'a', description: 'Alpha', color: 'ffffff' },
    { name: 'b', description: 'Bravo', color: '000000' },
    { name: 'c', description: 'Charlie', color: '111111' }
  ];
  const existing = [
    { name: 'A', description: 'Old Alpha', color: 'FFFFFF' },
    { name: 'b', description: 'Bravo', color: '000000' }
  ];

  const plan = buildLabelPlan(desired, existing);
  assert.equal(plan.length, 3);
  assert.deepEqual(plan.map((entry) => entry.type), ['update', 'noop', 'create']);
  assert.equal(plan[0].currentName, 'A');
});

test('runBootstrapContracts dry-run reports planned operations and policy pass', async () => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'bootstrap-contracts-dry-run-'));
  const labelsPolicyPath = path.join(tmpDir, 'labels.json');
  const reportPath = path.join(tmpDir, 'report.json');
  const policyReportPath = path.join(tmpDir, 'policy-report.json');
  fs.writeFileSync(
    labelsPolicyPath,
    `${JSON.stringify(
      {
        schema: LABEL_POLICY_SCHEMA,
        schemaVersion: '1.0.0',
        labels: [
          { name: 'standing-priority', description: 'Primary', color: 'FFFFFF' },
          { name: 'queue-blocked', description: 'Blocked', color: 'D93F0B' }
        ]
      },
      null,
      2
    )}\n`,
    'utf8'
  );

  const result = await runBootstrapContracts({
    argv: [
      'node',
      'bootstrap-contracts.mjs',
      '--repo',
      'example/repo',
      '--labels-policy',
      labelsPolicyPath,
      '--report',
      reportPath,
      '--policy-report',
      policyReportPath,
      '--dry-run'
    ],
    repoRoot: tmpDir,
    runPolicyCheckFn: async ({ argv }) => {
      const index = argv.indexOf('--report');
      const outputPath = argv[index + 1];
      fs.writeFileSync(
        outputPath,
        `${JSON.stringify({ schema: 'priority/policy-report@v1', result: 'pass' }, null, 2)}\n`,
        'utf8'
      );
      return 0;
    }
  });

  assert.equal(result.exitCode, 0);
  assert.equal(result.report.status, 'pass');
  assert.equal(result.report.labels.createdCount, 2);
  assert.equal(result.report.labels.updatedCount, 0);
  assert.equal(result.report.policy.executed, true);
  assert.equal(result.report.policy.result, 'pass');

  const persisted = JSON.parse(fs.readFileSync(reportPath, 'utf8'));
  assert.equal(persisted.schema, 'priority/bootstrap-contracts-report@v1');
  assert.equal(persisted.status, 'pass');
});

test('runBootstrapContracts non-dry-run creates/updates labels and strict policy fails on skip', async () => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'bootstrap-contracts-apply-'));
  const labelsPolicyPath = path.join(tmpDir, 'labels.json');
  const reportPath = path.join(tmpDir, 'report.json');
  const policyReportPath = path.join(tmpDir, 'policy-report.json');
  fs.writeFileSync(
    labelsPolicyPath,
    `${JSON.stringify(
      {
        schema: LABEL_POLICY_SCHEMA,
        schemaVersion: '1.0.0',
        labels: [
          { name: 'standing-priority', description: 'Current top objective', color: 'FFFFFF' },
          { name: 'queue-blocked', description: 'Queue blocked', color: 'D93F0B' }
        ]
      },
      null,
      2
    )}\n`,
    'utf8'
  );

  const requests = [];
  const existingLabels = [{ name: 'standing-priority', description: 'old', color: 'ffffff' }];
  const fetchFn = async (url, options = {}) => {
    const method = options.method || 'GET';
    requests.push({ method, url });
    if (method === 'GET' && url.includes('/labels?per_page=100')) {
      return {
        ok: true,
        status: 200,
        text: async () => JSON.stringify(existingLabels)
      };
    }
    if (method === 'POST' && url.endsWith('/labels')) {
      return {
        ok: true,
        status: 201,
        text: async () => JSON.stringify({ ok: true })
      };
    }
    if (method === 'PATCH' && url.includes('/labels/standing-priority')) {
      return {
        ok: true,
        status: 200,
        text: async () => JSON.stringify({ ok: true })
      };
    }
    return {
      ok: false,
      status: 404,
      text: async () => ''
    };
  };

  const result = await runBootstrapContracts({
    argv: [
      'node',
      'bootstrap-contracts.mjs',
      '--repo',
      'example/repo',
      '--labels-policy',
      labelsPolicyPath,
      '--report',
      reportPath,
      '--policy-report',
      policyReportPath,
      '--strict-policy'
    ],
    repoRoot: tmpDir,
    fetchFn,
    resolveTokenFn: () => 'token',
    runPolicyCheckFn: async ({ argv }) => {
      const index = argv.indexOf('--report');
      const outputPath = argv[index + 1];
      fs.writeFileSync(
        outputPath,
        `${JSON.stringify({ schema: 'priority/policy-report@v1', result: 'skipped' }, null, 2)}\n`,
        'utf8'
      );
      return 0;
    }
  });

  assert.equal(result.exitCode, 1);
  assert.equal(result.report.status, 'fail');
  assert.equal(result.report.labels.updatedCount, 1);
  assert.equal(result.report.labels.createdCount, 1);
  assert.equal(result.report.policy.result, 'skipped');
  assert.ok(result.report.errors.some((entry) => entry.includes("strict mode")));

  assert.equal(requests.filter((entry) => entry.method === 'GET').length, 1);
  assert.equal(requests.filter((entry) => entry.method === 'PATCH').length, 1);
  assert.equal(requests.filter((entry) => entry.method === 'POST').length, 1);
});

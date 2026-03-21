#!/usr/bin/env node

import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {
  collectPackageState,
  DEFAULT_MODE,
  DEFAULT_OUTPUT_PATH,
  DEFAULT_RAW_OUTPUT_PATH,
  DEFAULT_THRESHOLDS,
  parseArgs,
  runDependencyAudit,
  summarizeAuditPayload,
} from '../dependency-audit.mjs';

function createAuditPayload(overrides = {}) {
  return {
    auditReportVersion: 2,
    vulnerabilities: {},
    metadata: {
      vulnerabilities: {
        info: 0,
        low: 0,
        moderate: 0,
        high: 0,
        critical: 0,
        total: 0,
      },
      dependencies: {
        prod: 10,
        dev: 5,
        optional: 1,
        peer: 0,
        peerOptional: 0,
        total: 16,
      },
    },
    ...overrides,
  };
}

test('parseArgs supports mode, outputs, and thresholds', () => {
  const parsed = parseArgs([
    'node',
    'dependency-audit.mjs',
    '--repo-root',
    'repo-root',
    '--output',
    'custom-report.json',
    '--raw-output',
    'custom-raw.json',
    '--mode',
    'enforce',
    '--threshold-total',
    '2',
    '--threshold-critical',
    '1',
    '--threshold-high',
    '3',
    '--threshold-moderate',
    '4',
  ]);

  assert.equal(parsed.repoRoot, 'repo-root');
  assert.equal(parsed.outputPath, 'custom-report.json');
  assert.equal(parsed.rawOutputPath, 'custom-raw.json');
  assert.equal(parsed.mode, 'enforce');
  assert.deepEqual(parsed.thresholds, {
    total: 2,
    critical: 1,
    high: 3,
    moderate: 4,
  });
});

test('summarizeAuditPayload extracts package rows and breached thresholds', () => {
  const summarized = summarizeAuditPayload(
    createAuditPayload({
      vulnerabilities: {
        undici: {
          severity: 'high',
          isDirect: true,
          range: '<6.24.0',
          fixAvailable: {
            name: 'undici',
            version: '6.24.0',
            isSemVerMajor: false,
          },
          via: [
            {
              source: 10,
              severity: 'high',
            },
          ],
          nodes: ['node_modules/undici'],
        },
        'markdown-it': {
          severity: 'moderate',
          isDirect: false,
          range: '<14.1.1',
          fixAvailable: false,
          via: ['markdownlint'],
          nodes: ['node_modules/markdown-it'],
        },
      },
      metadata: {
        vulnerabilities: {
          info: 0,
          low: 0,
          moderate: 1,
          high: 1,
          critical: 0,
          total: 2,
        },
        dependencies: {
          prod: 10,
          dev: 5,
          optional: 1,
          peer: 0,
          peerOptional: 0,
          total: 16,
        },
      },
    }),
    {
      total: 0,
      critical: 0,
      high: 0,
      moderate: 0,
    },
  );

  assert.equal(summarized.summary.total, 2);
  assert.deepEqual(
    summarized.packages.map((entry) => ({ name: entry.name, severity: entry.severity })),
    [
      { name: 'undici', severity: 'high' },
      { name: 'markdown-it', severity: 'moderate' },
    ],
  );
  assert.deepEqual(
    summarized.breaches.map((entry) => entry.key),
    ['total', 'high', 'moderate'],
  );
});

test('runDependencyAudit reports clean audits as pass in observe mode', async () => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'dependency-audit-pass-'));
  const outputPath = path.join(tmpDir, 'report.json');
  const rawOutputPath = path.join(tmpDir, 'npm-audit.json');
  fs.writeFileSync(
    path.join(tmpDir, 'package.json'),
    JSON.stringify({ name: 'audit-pass', version: '1.2.3' }, null, 2),
    'utf8',
  );
  fs.writeFileSync(
    path.join(tmpDir, 'package-lock.json'),
    JSON.stringify({ name: 'audit-pass', lockfileVersion: 3 }, null, 2),
    'utf8',
  );

  const result = await runDependencyAudit(
    {
      repoRoot: tmpDir,
      outputPath,
      rawOutputPath,
      mode: 'observe',
      thresholds: { ...DEFAULT_THRESHOLDS },
    },
    {
      runAuditCommandFn: async () => ({
        command: 'node',
        args: ['npm-cli.js', 'audit', '--json'],
        stdout: `${JSON.stringify(createAuditPayload(), null, 2)}\n`,
        stderr: '',
        exitCode: 0,
        error: null,
      }),
      log: () => {},
      error: () => {},
    },
  );

  assert.equal(result.exitCode, 0);
  assert.equal(result.report.result, 'pass');
  assert.equal(result.report.packageState.packageJson.packageName, 'audit-pass');
  assert.equal(result.report.packageState.packageJson.packageVersion, '1.2.3');
  assert.equal(result.report.packageState.packageLock.lockfileVersion, 3);
  assert.match(result.report.packageState.fingerprintSha256, /^[0-9a-f]{64}$/);
  assert.equal(result.report.summary.total, 0);
  assert.equal(fs.existsSync(outputPath), true);
  assert.equal(fs.existsSync(rawOutputPath), true);
});

test('runDependencyAudit warns without failing in observe mode when thresholds are breached', async () => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'dependency-audit-warn-'));
  const outputPath = path.join(tmpDir, 'report.json');
  const rawOutputPath = path.join(tmpDir, 'npm-audit.json');
  fs.writeFileSync(path.join(tmpDir, 'package.json'), JSON.stringify({ name: 'audit-warn', version: '1.0.0' }), 'utf8');

  const result = await runDependencyAudit(
    {
      repoRoot: tmpDir,
      outputPath,
      rawOutputPath,
      mode: 'observe',
      thresholds: { ...DEFAULT_THRESHOLDS },
    },
    {
      runAuditCommandFn: async () => ({
        command: 'node',
        args: ['npm-cli.js', 'audit', '--json'],
        stdout: `${JSON.stringify(createAuditPayload({
          vulnerabilities: {
            ajv: {
              severity: 'moderate',
              isDirect: true,
              range: '<8.18.0',
              fixAvailable: true,
              via: [],
              nodes: ['node_modules/ajv'],
            },
          },
          metadata: {
            vulnerabilities: {
              info: 0,
              low: 0,
              moderate: 1,
              high: 0,
              critical: 0,
              total: 1,
            },
            dependencies: {
              prod: 10,
              dev: 5,
              optional: 1,
              peer: 0,
              peerOptional: 0,
              total: 16,
            },
          },
        }), null, 2)}\n`,
        stderr: '',
        exitCode: 1,
        error: null,
      }),
      log: () => {},
      error: () => {},
    },
  );

  assert.equal(result.exitCode, 0);
  assert.equal(result.report.result, 'warn');
  assert.deepEqual(
    result.report.breaches.map((entry) => entry.key),
    ['total', 'moderate'],
  );
});

test('runDependencyAudit fails in enforce mode when thresholds are breached', async () => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'dependency-audit-fail-'));
  fs.writeFileSync(path.join(tmpDir, 'package.json'), JSON.stringify({ name: 'audit-fail', version: '2.0.0' }), 'utf8');

  const result = await runDependencyAudit(
    {
      repoRoot: tmpDir,
      outputPath: path.join(tmpDir, 'report.json'),
      rawOutputPath: path.join(tmpDir, 'npm-audit.json'),
      mode: 'enforce',
      thresholds: { ...DEFAULT_THRESHOLDS },
    },
    {
      runAuditCommandFn: async () => ({
        command: 'node',
        args: ['npm-cli.js', 'audit', '--json'],
        stdout: `${JSON.stringify(createAuditPayload({
          vulnerabilities: {
            undici: {
              severity: 'high',
              isDirect: true,
              range: '<6.24.0',
              fixAvailable: true,
              via: [],
              nodes: ['node_modules/undici'],
            },
          },
          metadata: {
            vulnerabilities: {
              info: 0,
              low: 0,
              moderate: 0,
              high: 1,
              critical: 0,
              total: 1,
            },
            dependencies: {
              prod: 10,
              dev: 5,
              optional: 1,
              peer: 0,
              peerOptional: 0,
              total: 16,
            },
          },
        }), null, 2)}\n`,
        stderr: '',
        exitCode: 1,
        error: null,
      }),
      log: () => {},
      error: () => {},
    },
  );

  assert.equal(result.exitCode, 1);
  assert.equal(result.report.result, 'fail');
});

test('runDependencyAudit records execution errors without failing observe mode', async () => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'dependency-audit-error-'));
  fs.writeFileSync(path.join(tmpDir, 'package.json'), JSON.stringify({ name: 'audit-error', version: '3.0.0' }), 'utf8');

  const result = await runDependencyAudit(
    {
      repoRoot: tmpDir,
      outputPath: path.join(tmpDir, 'report.json'),
      rawOutputPath: path.join(tmpDir, 'npm-audit.json'),
      mode: 'observe',
      thresholds: { ...DEFAULT_THRESHOLDS },
    },
    {
      runAuditCommandFn: async () => ({
        command: 'node',
        args: ['npm-cli.js', 'audit', '--json'],
        stdout: '',
        stderr: 'registry timeout',
        exitCode: -1,
        error: 'spawn failed',
      }),
      log: () => {},
      error: () => {},
    },
  );

  assert.equal(result.exitCode, 0);
  assert.equal(result.report.result, 'error');
  assert.equal(result.report.errors.length >= 1, true);
});

test('collectPackageState fingerprints the audited package manifest and lockfile deterministically', async () => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'dependency-audit-package-state-'));
  fs.writeFileSync(
    path.join(tmpDir, 'package.json'),
    JSON.stringify({ name: 'package-state', version: '9.9.9' }, null, 2),
    'utf8',
  );
  fs.writeFileSync(
    path.join(tmpDir, 'package-lock.json'),
    JSON.stringify({ name: 'package-state', lockfileVersion: 3 }, null, 2),
    'utf8',
  );

  const first = await collectPackageState({ repoRoot: tmpDir }, { nodeVersion: 'v24.13.1' });
  const second = await collectPackageState({ repoRoot: tmpDir }, { nodeVersion: 'v24.13.1' });

  assert.equal(first.packageJson.path, 'package.json');
  assert.equal(first.packageLock.path, 'package-lock.json');
  assert.equal(first.packageJson.packageName, 'package-state');
  assert.equal(first.packageJson.packageVersion, '9.9.9');
  assert.equal(first.packageLock.lockfileVersion, 3);
  assert.match(first.packageJson.sha256, /^[0-9a-f]{64}$/);
  assert.match(first.packageLock.sha256, /^[0-9a-f]{64}$/);
  assert.equal(first.fingerprintSha256, second.fingerprintSha256);
});

test('parseArgs defaults align with the contract', () => {
  const parsed = parseArgs(['node', 'dependency-audit.mjs']);
  assert.equal(parsed.repoRoot, '.');
  assert.equal(parsed.outputPath, DEFAULT_OUTPUT_PATH);
  assert.equal(parsed.rawOutputPath, DEFAULT_RAW_OUTPUT_PATH);
  assert.equal(parsed.mode, DEFAULT_MODE);
  assert.deepEqual(parsed.thresholds, DEFAULT_THRESHOLDS);
});

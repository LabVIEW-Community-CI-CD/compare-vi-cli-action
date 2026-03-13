#!/usr/bin/env node

import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, mkdir, writeFile } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import {
  buildDockerDesktopReviewLoopPowerShellArgs,
  buildLocalReviewLoopCliArgs,
  runDockerDesktopReviewLoop
} from '../docker-desktop-review-loop.mjs';

test('buildLocalReviewLoopCliArgs forwards receipt, requirements, and single-VI history inputs', () => {
  const args = buildLocalReviewLoopCliArgs({
    repoRoot: '/tmp/repo',
    request: {
      requested: true,
      receiptPath: 'tests/results/docker-tools-parity/review-loop-receipt.json',
      actionlint: false,
      markdownlint: false,
      docs: false,
      workflow: false,
      dotnetCliBuild: false,
      requirementsVerification: true,
      niLinuxReviewSuite: true,
      singleViHistory: {
        enabled: true,
        targetPath: 'fixtures/vi-attr/Head.vi',
        branchRef: 'develop',
        baselineRef: 'upstream/develop',
        maxCommitCount: 256
      }
    }
  });

  assert.deepEqual(args, [
    '--repo-root',
    '/tmp/repo',
    '--receipt-path',
    'tests/results/docker-tools-parity/review-loop-receipt.json',
    '--skip-actionlint',
    '--skip-markdown',
    '--skip-docs',
    '--skip-workflow',
    '--skip-dotnet-cli-build',
    '--requirements-verification',
    '--ni-linux-review-suite',
    '--history-target-path',
    'fixtures/vi-attr/Head.vi',
    '--history-branch-ref',
    'develop',
    '--history-baseline-ref',
    'upstream/develop',
    '--history-max-commit-count',
    '256'
  ]);
});

test('buildDockerDesktopReviewLoopPowerShellArgs uses the Docker helper contract', () => {
  const args = buildDockerDesktopReviewLoopPowerShellArgs({
    requested: true,
    receiptPath: 'tests/results/docker-tools-parity/review-loop-receipt.json',
    actionlint: true,
    markdownlint: true,
    docs: true,
    workflow: true,
    dotnetCliBuild: true,
    requirementsVerification: true,
    niLinuxReviewSuite: true,
    singleViHistory: {
      enabled: true,
      targetPath: 'fixtures/vi-attr/Head.vi',
      branchRef: 'develop',
      baselineRef: '',
      maxCommitCount: 128
    }
  });

  assert.deepEqual(args.slice(0, 6), [
    '-NoLogo',
    '-NoProfile',
    '-File',
    path.join('tools', 'Run-NonLVChecksInDocker.ps1'),
    '-UseToolsImage',
    '-DockerParityReviewReceiptPath'
  ]);
  assert.match(args.join(' '), /-RequirementsVerification/);
  assert.match(args.join(' '), /-NILinuxReviewSuite/);
  assert.match(args.join(' '), /-NILinuxReviewSuiteHistoryTargetPath/);
});

test('buildDockerDesktopReviewLoopPowerShellArgs only emits skip flags when explicitly requested', () => {
  const args = buildDockerDesktopReviewLoopPowerShellArgs({
    requested: true,
    receiptPath: 'tests/results/docker-tools-parity/review-loop-receipt.json',
    actionlint: false,
    markdownlint: false,
    docs: false,
    workflow: false,
    dotnetCliBuild: false,
    requirementsVerification: false,
    niLinuxReviewSuite: false
  });

  assert.match(args.join(' '), /-SkipActionlint/);
  assert.match(args.join(' '), /-SkipMarkdown/);
  assert.match(args.join(' '), /-SkipDocs/);
  assert.match(args.join(' '), /-SkipWorkflow/);
  assert.match(args.join(' '), /-SkipDotnetCliBuild/);
});

test('runDockerDesktopReviewLoop returns passed when the receipt reports passed', async () => {
  const repoRoot = await mkdtemp(path.join(os.tmpdir(), 'docker-desktop-review-loop-'));
  const receiptPath = path.join(repoRoot, 'tests', 'results', 'docker-tools-parity', 'review-loop-receipt.json');

  const result = await runDockerDesktopReviewLoop({
    repoRoot,
    request: {
      requested: true,
      receiptPath: path.relative(repoRoot, receiptPath),
      markdownlint: true,
      requirementsVerification: true,
      niLinuxReviewSuite: false
    },
    runCommandFn: async () => {
      await mkdir(path.dirname(receiptPath), { recursive: true });
      await writeFile(
        receiptPath,
        `${JSON.stringify({
          schema: 'docker-tools-parity-review-loop@v1',
          overall: { status: 'passed', failedCheck: '', message: '', exitCode: 0 }
        })}\n`,
        'utf8'
      );
      return {
        status: 0,
        stdout: '',
        stderr: ''
      };
    }
  });

  assert.equal(result.status, 'passed');
  assert.equal(result.receipt.overall.status, 'passed');
});

test('runDockerDesktopReviewLoop fails closed when the receipt reports a failed check', async () => {
  const repoRoot = await mkdtemp(path.join(os.tmpdir(), 'docker-desktop-review-loop-fail-'));
  const receiptPath = path.join(repoRoot, 'tests', 'results', 'docker-tools-parity', 'review-loop-receipt.json');
  await mkdir(path.dirname(receiptPath), { recursive: true });
  await writeFile(
    receiptPath,
    `${JSON.stringify({
      schema: 'docker-tools-parity-review-loop@v1',
      overall: { status: 'failed', failedCheck: 'markdownlint', message: 'markdownlint failed', exitCode: 1 }
    })}\n`,
    'utf8'
  );

  const result = await runDockerDesktopReviewLoop({
    repoRoot,
    request: {
      requested: true,
      receiptPath: path.relative(repoRoot, receiptPath),
      markdownlint: true,
      requirementsVerification: false,
      niLinuxReviewSuite: false
    },
    runCommandFn: () => ({
      status: 1,
      stdout: '',
      stderr: 'markdownlint failed'
    })
  });

  assert.equal(result.status, 'failed');
  assert.match(result.reason, /markdownlint/i);
});

test('runDockerDesktopReviewLoop fails closed with a deterministic reason when the receipt JSON is corrupt', async () => {
  const repoRoot = await mkdtemp(path.join(os.tmpdir(), 'docker-desktop-review-loop-corrupt-'));
  const receiptPath = path.join(repoRoot, 'tests', 'results', 'docker-tools-parity', 'review-loop-receipt.json');

  const result = await runDockerDesktopReviewLoop({
    repoRoot,
    request: {
      requested: true,
      receiptPath: path.relative(repoRoot, receiptPath),
      markdownlint: true,
      requirementsVerification: false,
      niLinuxReviewSuite: false
    },
    runCommandFn: async () => {
      await mkdir(path.dirname(receiptPath), { recursive: true });
      await writeFile(receiptPath, '{ not-json }\n', 'utf8');
      return {
        status: 0,
        stdout: '',
        stderr: ''
      };
    }
  });

  assert.equal(result.status, 'failed');
  assert.match(result.reason, /corrupt receipt/i);
  assert.equal(result.receipt, null);
});

test('runDockerDesktopReviewLoop deletes stale receipts and fails closed on spawn errors', async () => {
  const repoRoot = await mkdtemp(path.join(os.tmpdir(), 'docker-desktop-review-loop-spawn-'));
  const receiptPath = path.join(repoRoot, 'tests', 'results', 'docker-tools-parity', 'review-loop-receipt.json');
  await mkdir(path.dirname(receiptPath), { recursive: true });
  await writeFile(
    receiptPath,
    `${JSON.stringify({
      schema: 'docker-tools-parity-review-loop@v1',
      overall: { status: 'passed', failedCheck: '', message: '', exitCode: 0 }
    })}\n`,
    'utf8'
  );

  const result = await runDockerDesktopReviewLoop({
    repoRoot,
    request: {
      requested: true,
      receiptPath: path.relative(repoRoot, receiptPath),
      markdownlint: true,
      requirementsVerification: false,
      niLinuxReviewSuite: false
    },
    runCommandFn: () => ({
      status: null,
      stdout: '',
      stderr: '',
      error: new Error('spawn pwsh ENOENT')
    })
  });

  assert.equal(result.status, 'failed');
  assert.match(result.reason, /spawn pwsh ENOENT/i);
  assert.equal(result.receipt, null);
});

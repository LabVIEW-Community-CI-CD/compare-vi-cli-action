#!/usr/bin/env node

import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, mkdir, writeFile } from 'node:fs/promises';
import { readFileSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {
  buildDockerDesktopReviewLoopPowerShellArgs,
  buildLocalReviewLoopCliArgs,
  DEFAULT_REVIEW_LOOP_MAX_BUFFER_BYTES,
  normalizeRequest,
  parseArgs,
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

test('normalizeRequest does not force NI Linux review from a stray single-VI target path', () => {
  const normalized = normalizeRequest({
    requested: true,
    niLinuxReviewSuite: false,
    singleViHistory: {
      enabled: false,
      targetPath: 'fixtures/vi-attr/Head.vi',
      branchRef: 'develop'
    }
  });

  assert.equal(normalized.niLinuxReviewSuite, false);
  assert.equal(normalized.singleViHistory.enabled, false);
});

test('parseArgs reports unknown trailing options as unknown instead of missing value', () => {
  assert.throws(
    () => parseArgs(['node', 'docker-desktop-review-loop.mjs', '--unknown']),
    /Unknown option: --unknown/
  );
});

test('parseArgs reports unknown options as unknown even when they have a trailing value', () => {
  assert.throws(
    () => parseArgs(['node', 'docker-desktop-review-loop.mjs', '--unknown', 'value']),
    /Unknown option: --unknown/
  );
});

test('parseArgs rejects unexpected positional arguments explicitly', () => {
  assert.throws(
    () => parseArgs(['node', 'docker-desktop-review-loop.mjs', 'unexpected']),
    /Unknown argument: unexpected/
  );
});

test('default docker desktop review-loop command pins an explicit spawn maxBuffer', () => {
  const source = readFileSync(new URL('../docker-desktop-review-loop.mjs', import.meta.url), 'utf8');
  assert.equal(DEFAULT_REVIEW_LOOP_MAX_BUFFER_BYTES, 64 * 1024 * 1024);
  assert.match(source, /maxBuffer:\s*DEFAULT_REVIEW_LOOP_MAX_BUFFER_BYTES/);
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
          git: {
            headSha: 'abc123',
            branch: 'issue/test',
            upstreamDevelopMergeBase: 'base123',
            dirtyTracked: false
          },
          overall: { status: 'passed', failedCheck: '', message: '', exitCode: 0 }
        })}\n`,
        'utf8'
      );
      return {
        status: 0,
        stdout: '',
        stderr: ''
      };
    },
    resolveRepoGitStateFn: () => ({
      headSha: 'abc123',
      branch: 'issue/test',
      upstreamDevelopMergeBase: 'base123'
    })
  });

  assert.equal(result.status, 'passed');
  assert.equal(result.receipt.overall.status, 'passed');
  assert.equal(result.receiptFreshForHead, true);
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

test('runDockerDesktopReviewLoop fails closed when the receipt head does not match the current repo head', async () => {
  const repoRoot = await mkdtemp(path.join(os.tmpdir(), 'docker-desktop-review-loop-stale-'));
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
      await writeFile(
        receiptPath,
        `${JSON.stringify({
          schema: 'docker-tools-parity-review-loop@v1',
          git: {
            headSha: 'stale-head',
            branch: 'issue/test',
            upstreamDevelopMergeBase: 'base123',
            dirtyTracked: false
          },
          overall: { status: 'passed', failedCheck: '', message: '', exitCode: 0 }
        })}\n`,
        'utf8'
      );
      return {
        status: 0,
        stdout: '',
        stderr: ''
      };
    },
    resolveRepoGitStateFn: () => ({
      headSha: 'current-head',
      branch: 'issue/test',
      upstreamDevelopMergeBase: 'base123'
    })
  });

  assert.equal(result.status, 'failed');
  assert.equal(result.receiptFreshForHead, false);
  assert.equal(result.receiptHeadSha, 'stale-head');
  assert.equal(result.currentHeadSha, 'current-head');
  assert.match(result.reason, /stale for the current HEAD/i);
});

test('runDockerDesktopReviewLoop rejects receipt paths outside docker parity results', async () => {
  const repoRoot = await mkdtemp(path.join(os.tmpdir(), 'docker-desktop-review-loop-path-'));

  const result = await runDockerDesktopReviewLoop({
    repoRoot,
    request: {
      requested: true,
      receiptPath: '../outside.json',
      markdownlint: true,
      requirementsVerification: false,
      niLinuxReviewSuite: false
    },
    runCommandFn: async () => {
      throw new Error('runCommandFn should not be called when receiptPath is invalid');
    }
  });

  assert.equal(result.status, 'failed');
  assert.match(result.reason, /must stay under tests\/results\/docker-tools-parity|escapes the repository root/i);
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

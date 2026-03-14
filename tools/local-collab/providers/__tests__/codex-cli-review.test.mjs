#!/usr/bin/env node

import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdirSync, writeFileSync } from 'node:fs';
import { mkdtemp, readFile, writeFile } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import {
  normalizeCodexCliReviewPolicy,
  resolveWslCodexRuntime,
  runCodexCliReview
} from '../codex-cli-review.mjs';

async function createGitRepo() {
  const repoRoot = await mkdtemp(path.join(os.tmpdir(), 'codex-cli-review-'));
  spawnSync('git', ['init', '--initial-branch=develop'], { cwd: repoRoot, encoding: 'utf8' });
  await writeFile(path.join(repoRoot, 'README.md'), '# test\n', 'utf8');
  spawnSync('git', ['add', 'README.md'], { cwd: repoRoot, encoding: 'utf8' });
  spawnSync(
    'git',
    ['-c', 'user.name=Test User', '-c', 'user.email=test@example.com', 'commit', '-m', 'initial'],
    { cwd: repoRoot, encoding: 'utf8' }
  );
  await writeFile(path.join(repoRoot, 'README.md'), '# changed\n', 'utf8');
  spawnSync('git', ['add', 'README.md'], { cwd: repoRoot, encoding: 'utf8' });
  return repoRoot;
}

test('normalizeCodexCliReviewPolicy keeps WSL2 defaults for the personal/codex plane', () => {
  const policy = normalizeCodexCliReviewPolicy({});
  assert.equal(policy.enabled, false);
  assert.equal(policy.distro, 'Ubuntu');
  assert.equal(policy.executionPlane, 'wsl2');
  assert.equal(policy.ephemeral, true);
});

test('resolveWslCodexRuntime fails closed when codex is unavailable in the distro', () => {
  assert.throws(
    () => resolveWslCodexRuntime({
      repoRoot: process.cwd(),
      distro: 'Ubuntu',
      runWslCommandFn: () => ({
        status: 1,
        stdout: '',
        stderr: 'codex: command not found'
      })
    }),
    /Codex CLI is not available/i
  );
});

test('runCodexCliReview writes a deterministic passed receipt from a WSL-backed codex review', async () => {
  const repoRoot = await createGitRepo();
  let codexInvoked = false;

  const result = await runCodexCliReview({
    repoRoot,
    profile: 'pre-commit',
    stagedFiles: ['README.md'],
    policy: {
      enabled: true,
      distro: 'Ubuntu',
      model: 'gpt-5-codex',
      executionPlane: 'wsl2'
    },
    runWslCommandFn: (distro, args) => {
      if (args[0] === 'wslpath') {
        return {
          status: 0,
          stdout: args[2].replace(/\\/g, '/').replace(/^C:/i, '/mnt/c'),
          stderr: ''
        };
      }
      if (args[0] === 'bash' && args[2] === 'command -v codex') {
        return {
          status: 0,
          stdout: '/home/sveld/.local/bin/codex\n',
          stderr: ''
        };
      }
      if (!codexInvoked) {
        codexInvoked = true;
        const responsePath = path.join(repoRoot, 'tests', 'results', '_hooks', 'pre-commit-codex-cli-review.jsonl');
        const lastMessagePath = path.join(repoRoot, 'tests', 'results', '_hooks', 'pre-commit-codex-cli-review.last-message.json');
        mkdirSync(path.dirname(responsePath), { recursive: true });
        writeFileSync(
          responsePath,
          [
            '{"type":"thread.started","thread_id":"thread-1"}',
            '{"type":"turn.completed","usage":{"input_tokens":210,"cached_input_tokens":80,"output_tokens":55}}'
          ].join('\n'),
        );
        writeFileSync(lastMessagePath, '{"status":"approved","summary":"Codex CLI passed.","findings":[]}', 'utf8');
      }
      return {
        status: 0,
        stdout: '',
        stderr: ''
      };
    }
  });

  assert.equal(result.status, 'passed');
  assert.equal(result.executionPlane, 'wsl2');
  assert.equal(result.providerRuntime, 'codex-cli');
  assert.equal(result.requestedModel, 'gpt-5-codex');

  const persisted = JSON.parse(await readFile(path.join(repoRoot, result.receiptPath), 'utf8'));
  assert.equal(persisted.executionPlane, 'wsl2');
  assert.equal(persisted.providerRuntime, 'codex-cli');
});

test('runCodexCliReview fails closed when the WSL runtime cannot be resolved', async () => {
  const repoRoot = await createGitRepo();
  const result = await runCodexCliReview({
    repoRoot,
    profile: 'pre-commit',
    stagedFiles: ['README.md'],
    policy: {
      enabled: true,
      distro: 'MissingDistro'
    },
    runWslCommandFn: () => ({
      status: 1,
      stdout: '',
      stderr: 'The system cannot find the file specified.'
    })
  });

  assert.equal(result.status, 'failed');
  assert.match(result.reason, /Codex CLI is not available|Unable to access WSL2/i);
});

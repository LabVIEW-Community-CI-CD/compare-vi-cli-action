#!/usr/bin/env node

import test from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { access, mkdtemp, readFile, writeFile } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import {
  DEFAULT_COPILOT_CLI_REVIEW_POLICY,
  buildReviewPrompt,
  normalizeCopilotCliReviewPolicy,
  runCopilotCliReview
} from '../copilot-cli-review.mjs';

function runGit(repoRoot, args) {
  const result = spawnSync('git', ['-C', repoRoot, ...args], {
    encoding: 'utf8',
    stdio: ['ignore', 'pipe', 'pipe']
  });
  assert.equal(result.status, 0, result.stderr || result.stdout || `git ${args.join(' ')} failed`);
  return result.stdout.trim();
}

test('normalizeCopilotCliReviewPolicy keeps the prompt-only no-tool default', () => {
  const policy = normalizeCopilotCliReviewPolicy({});
  assert.equal(policy.allowAllTools, false);
  assert.equal(policy.availableTools, '');
  assert.equal(policy.promptOnly, true);
  assert.deepEqual(policy.convergence, {
    minPasses: 2,
    maxPasses: 4,
    stopOnCleanPass: true,
    stopOnNoNovelFindingsCount: 2,
    promoteInstructionGapAfterRepeatedFindings: 2
  });
  assert.deepEqual(policy.collaboration, DEFAULT_COPILOT_CLI_REVIEW_POLICY.collaboration);
});

test('buildReviewPrompt includes collaboration planes and instruction presence', () => {
  const prompt = buildReviewPrompt({
    collaboration: DEFAULT_COPILOT_CLI_REVIEW_POLICY.collaboration,
    context: {
      mode: 'staged',
      git: {
        headSha: 'abc123',
        branch: 'issue/test'
      },
      baseRef: null,
      selectedFiles: ['docs/example.md'],
      omittedFileCount: 0,
      diffBytes: 12,
      diffTruncated: false,
      diffText: 'diff --git a/docs/example.md b/docs/example.md'
    },
    instructionSources: {
      present: ['AGENTS.md', '.github/instructions/draft-only-copilot-review.instructions.md'],
      missing: ['.github/copilot-instructions.md']
    },
    profileName: 'preCommit',
    repoRoot: '/tmp/repo'
  });

  assert.match(prompt, /Authoring plane: personal \(codex\)/);
  assert.match(prompt, /Review plane: origin \(copilot-cli\)/);
  assert.match(prompt, /AGENTS\.md/);
  assert.match(prompt, /\.github\/copilot-instructions\.md/);
});

test('runCopilotCliReview writes a deterministic passed receipt for staged review', async () => {
  const repoRoot = await mkdtemp(path.join(os.tmpdir(), 'copilot-cli-review-'));
  runGit(repoRoot, ['init']);
  runGit(repoRoot, ['config', 'user.name', 'Agent Runner']);
  runGit(repoRoot, ['config', 'user.email', 'agent@example.com']);
  await writeFile(path.join(repoRoot, 'AGENTS.md'), '# Agent handbook\n', 'utf8');
  await writeFile(path.join(repoRoot, 'README.md'), '# repo\n', 'utf8');
  runGit(repoRoot, ['add', 'AGENTS.md', 'README.md']);
  runGit(repoRoot, ['commit', '-m', 'init']);
  await writeFile(path.join(repoRoot, 'README.md'), '# repo\n\nupdated\n', 'utf8');
  runGit(repoRoot, ['add', 'README.md']);

  const result = await runCopilotCliReview({
    repoRoot,
    profile: 'pre-commit',
    stagedFiles: ['README.md'],
    policy: {
      ...DEFAULT_COPILOT_CLI_REVIEW_POLICY,
      profiles: {
        ...DEFAULT_COPILOT_CLI_REVIEW_POLICY.profiles,
        preCommit: {
          ...DEFAULT_COPILOT_CLI_REVIEW_POLICY.profiles.preCommit,
          receiptPath: 'tests/results/_hooks/pre-commit-copilot-cli-review.json'
        }
      }
    },
    runCommandFn: async () => ({
      status: 0,
      stdout: [
        JSON.stringify({ type: 'session.tools_updated', data: { model: 'gpt-5.4-mini' } }),
        JSON.stringify({
          type: 'assistant.message',
          data: {
            content: JSON.stringify({
              status: 'approved',
              summary: 'No actionable local findings.',
              findings: []
            })
          }
        }),
        JSON.stringify({ type: 'result', data: { ok: true } })
      ].join('\n'),
      stderr: ''
    })
  });

  assert.equal(result.status, 'passed');
  assert.equal(result.receipt.overall.status, 'passed');
  assert.equal(result.receipt.copilot.model, 'gpt-5.4-mini');
  assert.equal(result.receipt.context.selectedFiles[0], 'README.md');
  assert.equal(result.receipt.convergence.passCount, 2);
  assert.equal(result.receipt.convergence.stoppedReason, 'clean-pass');
  assert.equal(result.receipt.passes.length, 2);
  await access(path.join(repoRoot, 'tests', 'results', '_hooks', 'pre-commit-copilot-cli-review.prompt.txt'));
  await access(path.join(repoRoot, 'tests', 'results', '_hooks', 'pre-commit-copilot-cli-review.jsonl'));
  await access(path.join(repoRoot, 'tests', 'results', '_hooks', 'pre-commit-copilot-cli-review.pass-1.jsonl'));
  await access(path.join(repoRoot, 'tests', 'results', '_hooks', 'pre-commit-copilot-cli-review.pass-2.jsonl'));
});

test('runCopilotCliReview fails closed on actionable findings', async () => {
  const repoRoot = await mkdtemp(path.join(os.tmpdir(), 'copilot-cli-review-findings-'));
  runGit(repoRoot, ['init']);
  runGit(repoRoot, ['config', 'user.name', 'Agent Runner']);
  runGit(repoRoot, ['config', 'user.email', 'agent@example.com']);
  await writeFile(path.join(repoRoot, 'README.md'), '# repo\n', 'utf8');
  runGit(repoRoot, ['add', 'README.md']);
  runGit(repoRoot, ['commit', '-m', 'init']);
  await writeFile(path.join(repoRoot, 'README.md'), '# repo\n\nupdated\n', 'utf8');
  runGit(repoRoot, ['add', 'README.md']);

  const result = await runCopilotCliReview({
    repoRoot,
    profile: 'pre-commit',
    stagedFiles: ['README.md'],
    runCommandFn: async () => ({
      status: 0,
      stdout: JSON.stringify({
        type: 'assistant.message',
        data: {
          content: JSON.stringify({
            status: 'changes-requested',
            summary: 'Needs a fix.',
            findings: [
              {
                severity: 'warning',
                path: 'README.md',
                line: 2,
                title: 'Adjust wording',
                body: 'This line needs a correction.',
                actionable: true
              }
            ]
          })
        }
      }),
      stderr: ''
    })
  });

  assert.equal(result.status, 'failed');
  assert.equal(result.receipt.overall.actionableFindingCount, 1);
  assert.equal(result.receipt.findings[0].path, 'README.md');
  assert.equal(result.receipt.convergence.passCount, 3);
  assert.equal(result.receipt.convergence.stoppedReason, 'no-novel-findings');
  assert.equal(result.receipt.convergence.instructionGapCandidate, true);
  assert.equal(result.receipt.convergence.repeatedFindingFingerprints.length, 1);
});

test('runCopilotCliReview accumulates novel findings across bounded passes', async () => {
  const repoRoot = await mkdtemp(path.join(os.tmpdir(), 'copilot-cli-review-convergence-'));
  runGit(repoRoot, ['init']);
  runGit(repoRoot, ['config', 'user.name', 'Agent Runner']);
  runGit(repoRoot, ['config', 'user.email', 'agent@example.com']);
  await writeFile(path.join(repoRoot, 'README.md'), '# repo\n', 'utf8');
  runGit(repoRoot, ['add', 'README.md']);
  runGit(repoRoot, ['commit', '-m', 'init']);
  await writeFile(path.join(repoRoot, 'README.md'), '# repo\n\nupdated\n', 'utf8');
  runGit(repoRoot, ['add', 'README.md']);

  let invocation = 0;
  const payloads = [
    {
      status: 'changes-requested',
      summary: 'First finding.',
      findings: [
        {
          severity: 'warning',
          path: 'README.md',
          line: 2,
          title: 'Adjust wording',
          body: 'First finding body.',
          actionable: true
        }
      ]
    },
    {
      status: 'changes-requested',
      summary: 'Second finding.',
      findings: [
        {
          severity: 'warning',
          path: 'README.md',
          line: 2,
          title: 'Adjust wording',
          body: 'First finding body.',
          actionable: true
        },
        {
          severity: 'warning',
          path: 'README.md',
          line: 3,
          title: 'Add coverage',
          body: 'Second finding body.',
          actionable: true
        }
      ]
    },
    {
      status: 'changes-requested',
      summary: 'No novel findings remain.',
      findings: [
        {
          severity: 'warning',
          path: 'README.md',
          line: 2,
          title: 'Adjust wording',
          body: 'First finding body.',
          actionable: true
        },
        {
          severity: 'warning',
          path: 'README.md',
          line: 3,
          title: 'Add coverage',
          body: 'Second finding body.',
          actionable: true
        }
      ]
    },
    {
      status: 'changes-requested',
      summary: 'Still no novel findings remain.',
      findings: [
        {
          severity: 'warning',
          path: 'README.md',
          line: 2,
          title: 'Adjust wording',
          body: 'First finding body.',
          actionable: true
        },
        {
          severity: 'warning',
          path: 'README.md',
          line: 3,
          title: 'Add coverage',
          body: 'Second finding body.',
          actionable: true
        }
      ]
    }
  ];

  const result = await runCopilotCliReview({
    repoRoot,
    profile: 'pre-commit',
    stagedFiles: ['README.md'],
    runCommandFn: async () => {
      const payload = payloads[Math.min(invocation, payloads.length - 1)];
      invocation += 1;
      return {
        status: 0,
        stdout: [
          JSON.stringify({ type: 'session.tools_updated', data: { model: 'gpt-5.4' } }),
          JSON.stringify({
            type: 'assistant.message',
            data: {
              content: JSON.stringify(payload)
            }
          })
        ].join('\n'),
        stderr: ''
      };
    }
  });

  assert.equal(result.status, 'failed');
  assert.equal(result.receipt.overall.actionableFindingCount, 2);
  assert.equal(result.receipt.convergence.passCount, 4);
  assert.equal(result.receipt.convergence.stoppedReason, 'no-novel-findings');
  assert.equal(result.receipt.passes[0].novelActionableFindingCount, 1);
  assert.equal(result.receipt.passes[1].novelActionableFindingCount, 1);
  assert.equal(result.receipt.passes[2].novelActionableFindingCount, 0);
  assert.equal(result.receipt.passes[3].noNovelFindingStreak, 2);
});

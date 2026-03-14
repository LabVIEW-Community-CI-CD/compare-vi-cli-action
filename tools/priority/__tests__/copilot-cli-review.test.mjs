#!/usr/bin/env node

import test from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { access, mkdir, mkdtemp, readFile, writeFile } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import {
  DEFAULT_COPILOT_CLI_REVIEW_POLICY,
  buildReviewPrompt,
  collectReviewContext,
  loadCopilotCliReviewPolicy,
  normalizeCopilotCliReviewPolicy,
  resolveCopilotCliCommand,
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
  assert.deepEqual(policy.sessionPolicy, {
    reuse: 'fresh-per-head',
    scope: 'current-head',
    recordPromptArtifacts: true
  });
  assert.deepEqual(policy.convergence, {
    minPasses: 2,
    maxPasses: 4,
    stopOnCleanPass: true,
    stopOnNoNovelFindingsCount: 2,
    promoteInstructionGapAfterRepeatedFindings: 2
  });
  assert.deepEqual(policy.collaboration, DEFAULT_COPILOT_CLI_REVIEW_POLICY.collaboration);
});

test('loadCopilotCliReviewPolicy reads copilotCliReviewConfig and honors the boolean enable gate', async () => {
  const repoRoot = await mkdtemp(path.join(os.tmpdir(), 'copilot-cli-review-policy-'));
  await mkdir(path.join(repoRoot, 'tools', 'priority'), { recursive: true });
  await writeFile(
    path.join(repoRoot, 'tools', 'priority', 'delivery-agent.policy.json'),
    JSON.stringify({
      localReviewLoop: {
        copilotCliReview: false,
        copilotCliReviewConfig: {
          model: 'gpt-5.5-mini',
          availableTools: 'grep,cat',
          sessionPolicy: {
            reuse: 'fresh-per-invocation',
            scope: 'current-diff',
            recordPromptArtifacts: false
          }
        }
      }
    }, null, 2),
    'utf8'
  );

  const policy = await loadCopilotCliReviewPolicy(repoRoot);
  assert.equal(policy.enabled, false);
  assert.equal(policy.model, 'gpt-5.5-mini');
  assert.equal(policy.availableTools, 'grep,cat');
  assert.deepEqual(policy.sessionPolicy, {
    reuse: 'fresh-per-invocation',
    scope: 'current-diff',
    recordPromptArtifacts: false
  });
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
      present: [
        'AGENTS.md',
        '.github/copilot-instructions.md',
        '.github/instructions/draft-only-copilot-review.instructions.md'
      ],
      missing: []
    },
    profileName: 'preCommit',
    repoRoot: '/tmp/repo'
  });

  assert.match(prompt, /Authoring plane: personal \(codex\)/);
  assert.match(prompt, /Review plane: origin \(copilot-cli\)/);
  assert.match(prompt, /AGENTS\.md/);
  assert.match(prompt, /\.github\/copilot-instructions\.md/);
});

test('resolveCopilotCliCommand prefers the Windows npm shim bundle and launches through Node without shell mediation', async () => {
  const shimRoot = await mkdtemp(path.join(os.tmpdir(), 'copilot-cli-shim-'));
  const shimPath = path.join(shimRoot, 'copilot.cmd');
  const bundledNodePath = path.join(shimRoot, 'node.exe');
  const loaderPath = path.join(shimRoot, 'node_modules', '@github', 'copilot', 'npm-loader.js');
  await mkdir(path.dirname(loaderPath), { recursive: true });
  await writeFile(shimPath, '@echo off\r\necho copilot\r\n', 'utf8');
  await writeFile(bundledNodePath, '', 'utf8');
  await writeFile(loaderPath, 'console.log("copilot")\n', 'utf8');

  const invocation = resolveCopilotCliCommand('win32', {
    Path: shimRoot
  });

  assert.equal(invocation.command, 'copilot.cmd');
  assert.equal(invocation.spawnCommand, bundledNodePath);
  assert.deepEqual(invocation.spawnArgsPrefix, [loaderPath]);
  assert.equal(invocation.shell, false);
});

test('resolveCopilotCliCommand fails closed when no Windows shim can be resolved without shell mediation', () => {
  const invocation = resolveCopilotCliCommand('win32', {
    Path: ''
  });

  assert.equal(invocation.command, 'copilot.cmd');
  assert.equal(invocation.spawnCommand, null);
  assert.deepEqual(invocation.spawnArgsPrefix, []);
  assert.equal(invocation.shell, false);
  assert.match(invocation.resolutionError, /without shell mediation/i);
});

test('resolveCopilotCliCommand keeps scanning PATH after an unresolvable Windows shim', async () => {
  const brokenShimRoot = await mkdtemp(path.join(os.tmpdir(), 'copilot-cli-broken-shim-'));
  const healthyShimRoot = await mkdtemp(path.join(os.tmpdir(), 'copilot-cli-healthy-shim-'));
  const healthyLoaderPath = path.join(healthyShimRoot, 'node_modules', '@github', 'copilot', 'npm-loader.js');
  const healthyNodePath = path.join(healthyShimRoot, 'node.exe');
  await mkdir(path.dirname(healthyLoaderPath), { recursive: true });
  await writeFile(path.join(brokenShimRoot, 'copilot.cmd'), '@echo off\r\necho broken\r\n', 'utf8');
  await writeFile(path.join(healthyShimRoot, 'copilot.cmd'), '@echo off\r\necho healthy\r\n', 'utf8');
  await writeFile(healthyNodePath, '', 'utf8');
  await writeFile(healthyLoaderPath, 'console.log("copilot")\n', 'utf8');

  const invocation = resolveCopilotCliCommand('win32', {
    Path: [brokenShimRoot, healthyShimRoot].join(path.delimiter)
  });

  assert.equal(invocation.command, 'copilot.cmd');
  assert.equal(invocation.spawnCommand, healthyNodePath);
  assert.deepEqual(invocation.spawnArgsPrefix, [healthyLoaderPath]);
  assert.equal(invocation.shell, false);
  assert.equal(invocation.resolutionError, '');
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
  assert.equal(result.receipt.copilot.allowAllTools, false);
  assert.equal(result.receipt.copilot.command, process.platform === 'win32' ? 'copilot.cmd' : 'copilot');
  assert.equal(typeof result.receipt.copilot.shell, 'boolean');
  assert.deepEqual(result.receipt.permissionPolicy, {
    promptOnly: true,
    disableBuiltinMcps: true,
    allowAllTools: false,
    availableTools: ''
  });
  assert.equal(result.receipt.sessionPolicy.reuse, 'fresh-per-head');
  assert.equal(result.receipt.sessionPolicy.scope, 'current-head');
  assert.equal(result.receipt.sessionPolicy.reusedPriorSession, false);
  assert.match(result.receipt.sessionPolicy.checkpointKey, /^preCommit:/);
  assert.equal(result.receipt.context.selectedFiles[0], 'README.md');
  assert.equal(result.receipt.convergence.passCount, 2);
  assert.equal(result.receipt.convergence.stoppedReason, 'clean-pass');
  assert.equal(result.receipt.passes.length, 2);
  await access(path.join(repoRoot, 'tests', 'results', '_hooks', 'pre-commit-copilot-cli-review.prompt.txt'));
  await access(path.join(repoRoot, 'tests', 'results', '_hooks', 'pre-commit-copilot-cli-review.jsonl'));
  await access(path.join(repoRoot, 'tests', 'results', '_hooks', 'pre-commit-copilot-cli-review.pass-1.jsonl'));
  await access(path.join(repoRoot, 'tests', 'results', '_hooks', 'pre-commit-copilot-cli-review.pass-2.jsonl'));
});

test('runCopilotCliReview forwards non-empty availableTools allowlists to the CLI invocation', async () => {
  const repoRoot = await mkdtemp(path.join(os.tmpdir(), 'copilot-cli-review-tools-'));
  runGit(repoRoot, ['init']);
  runGit(repoRoot, ['config', 'user.name', 'Agent Runner']);
  runGit(repoRoot, ['config', 'user.email', 'agent@example.com']);
  await writeFile(path.join(repoRoot, 'README.md'), '# repo\n', 'utf8');
  runGit(repoRoot, ['add', 'README.md']);
  runGit(repoRoot, ['commit', '-m', 'init']);
  await writeFile(path.join(repoRoot, 'README.md'), '# repo\n\nupdated\n', 'utf8');
  runGit(repoRoot, ['add', 'README.md']);

  const invocations = [];
  const result = await runCopilotCliReview({
    repoRoot,
    profile: 'pre-commit',
    policy: {
      ...DEFAULT_COPILOT_CLI_REVIEW_POLICY,
      availableTools: 'grep,cat'
    },
    runCommandFn: async (command, args) => {
      invocations.push({ command, args });
      return {
        status: 0,
        stdout: JSON.stringify({
          type: 'assistant.message',
          data: {
            content: JSON.stringify({
              status: 'approved',
              summary: 'No actionable findings.',
              findings: []
            })
          }
        }),
        stderr: ''
      };
    }
  });

  assert.equal(result.status, 'passed');
  assert.match(invocations[0].args.join(' '), /--available-tools grep,cat/);
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

test('runCopilotCliReview supports report-only profiles when failOnFindings is disabled', async () => {
  const repoRoot = await mkdtemp(path.join(os.tmpdir(), 'copilot-cli-review-report-only-'));
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
    policy: {
      ...DEFAULT_COPILOT_CLI_REVIEW_POLICY,
      profiles: {
        ...DEFAULT_COPILOT_CLI_REVIEW_POLICY.profiles,
        preCommit: {
          ...DEFAULT_COPILOT_CLI_REVIEW_POLICY.profiles.preCommit,
          failOnFindings: false
        }
      }
    },
    runCommandFn: async () => ({
      status: 0,
      stdout: JSON.stringify({
        type: 'assistant.message',
        data: {
          content: JSON.stringify({
            status: 'changes-requested',
            summary: 'Needs follow-up.',
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

  assert.equal(result.status, 'passed');
  assert.equal(result.receipt.overall.status, 'passed');
  assert.match(result.receipt.overall.message, /report-only mode/i);
  assert.equal(result.receipt.overall.actionableFindingCount, 1);
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

test('runCopilotCliReview resolves head-mode merge base from the validate base sha env when upstream refs are absent', async () => {
  const repoRoot = await mkdtemp(path.join(os.tmpdir(), 'copilot-cli-review-head-env-'));
  runGit(repoRoot, ['init']);
  runGit(repoRoot, ['config', 'user.name', 'Agent Runner']);
  runGit(repoRoot, ['config', 'user.email', 'agent@example.com']);
  await writeFile(path.join(repoRoot, 'README.md'), '# repo\n', 'utf8');
  runGit(repoRoot, ['add', 'README.md']);
  runGit(repoRoot, ['commit', '-m', 'init']);
  const baseSha = runGit(repoRoot, ['rev-parse', 'HEAD']);
  await writeFile(path.join(repoRoot, 'docs.md'), '# docs\n', 'utf8');
  runGit(repoRoot, ['add', 'docs.md']);
  runGit(repoRoot, ['commit', '-m', 'update']);

  const previousValidateBaseSha = process.env.VALIDATE_BASE_SHA;
  const previousValidateBaseRef = process.env.VALIDATE_BASE_REF;
  try {
    process.env.VALIDATE_BASE_SHA = baseSha;
    process.env.VALIDATE_BASE_REF = 'develop';

    const result = await runCopilotCliReview({
      repoRoot,
      profile: 'daemon',
      runCommandFn: async () => ({
        status: 0,
        stdout: [
          JSON.stringify({ type: 'session.tools_updated', data: { model: 'gpt-5.4' } }),
          JSON.stringify({
            type: 'assistant.message',
            data: {
              content: JSON.stringify({
                status: 'approved',
                summary: 'No actionable findings.',
                findings: []
              })
            }
          })
        ].join('\n'),
        stderr: ''
      })
    });

    assert.equal(result.status, 'passed');
    assert.equal(result.receipt.context.baseRef, baseSha);
    assert.deepEqual(result.receipt.context.selectedFiles, ['docs.md']);
  } finally {
    if (previousValidateBaseSha == null) {
      delete process.env.VALIDATE_BASE_SHA;
    } else {
      process.env.VALIDATE_BASE_SHA = previousValidateBaseSha;
    }
    if (previousValidateBaseRef == null) {
      delete process.env.VALIDATE_BASE_REF;
    } else {
      process.env.VALIDATE_BASE_REF = previousValidateBaseRef;
    }
  }
});

test('runCopilotCliReview fetches the validate base in detached-head CI when only the PR head was checked out', async () => {
  const sourceRoot = await mkdtemp(path.join(os.tmpdir(), 'copilot-cli-review-source-'));
  runGit(sourceRoot, ['init']);
  runGit(sourceRoot, ['config', 'user.name', 'Agent Runner']);
  runGit(sourceRoot, ['config', 'user.email', 'agent@example.com']);
  await writeFile(path.join(sourceRoot, 'README.md'), '# repo\n', 'utf8');
  runGit(sourceRoot, ['add', 'README.md']);
  runGit(sourceRoot, ['commit', '-m', 'init']);
  runGit(sourceRoot, ['branch', '-M', 'develop']);
  const baseSha = runGit(sourceRoot, ['rev-parse', 'HEAD']);
  runGit(sourceRoot, ['switch', '-c', 'issue/test']);
  await writeFile(path.join(sourceRoot, 'docs.md'), '# docs\n', 'utf8');
  runGit(sourceRoot, ['add', 'docs.md']);
  runGit(sourceRoot, ['commit', '-m', 'update']);

  const remoteRoot = await mkdtemp(path.join(os.tmpdir(), 'copilot-cli-review-remote-'));
  runGit(path.dirname(remoteRoot), ['clone', '--bare', sourceRoot, remoteRoot]);

  const repoRoot = await mkdtemp(path.join(os.tmpdir(), 'copilot-cli-review-detached-'));
  runGit(repoRoot, ['init']);
  runGit(repoRoot, ['remote', 'add', 'origin', remoteRoot]);
  runGit(repoRoot, ['fetch', '--depth=1', 'origin', 'issue/test']);
  runGit(repoRoot, ['checkout', '--detach', 'FETCH_HEAD']);

  const previousGithubActions = process.env.GITHUB_ACTIONS;
  const previousValidateBaseSha = process.env.VALIDATE_BASE_SHA;
  const previousValidateBaseRef = process.env.VALIDATE_BASE_REF;
  try {
    process.env.GITHUB_ACTIONS = 'true';
    process.env.VALIDATE_BASE_SHA = baseSha;
    process.env.VALIDATE_BASE_REF = 'develop';

    const result = await runCopilotCliReview({
      repoRoot,
      profile: 'daemon',
      runCommandFn: async () => ({
        status: 0,
        stdout: [
          JSON.stringify({ type: 'session.tools_updated', data: { model: 'gpt-5.4' } }),
          JSON.stringify({
            type: 'assistant.message',
            data: {
              content: JSON.stringify({
                status: 'approved',
                summary: 'No actionable findings.',
                findings: []
              })
            }
          })
        ].join('\n'),
        stderr: ''
      })
    });

    assert.equal(result.status, 'passed');
    assert.equal(result.receipt.context.baseRef, baseSha);
    assert.deepEqual(result.receipt.context.selectedFiles, ['docs.md']);
  } finally {
    if (previousGithubActions == null) {
      delete process.env.GITHUB_ACTIONS;
    } else {
      process.env.GITHUB_ACTIONS = previousGithubActions;
    }
    if (previousValidateBaseSha == null) {
      delete process.env.VALIDATE_BASE_SHA;
    } else {
      process.env.VALIDATE_BASE_SHA = previousValidateBaseSha;
    }
    if (previousValidateBaseRef == null) {
      delete process.env.VALIDATE_BASE_REF;
    } else {
      process.env.VALIDATE_BASE_REF = previousValidateBaseRef;
    }
  }
});

test('collectReviewContext fails closed when staged file discovery errors', () => {
  const repoRoot = 'C:/repo';
  const runGitFn = (candidateRepoRoot, args) => {
    assert.equal(candidateRepoRoot, repoRoot);
    if (args.join(' ') === 'rev-parse HEAD') {
      return { status: 0, stdout: 'abc123\n', stderr: '' };
    }
    if (args.join(' ') === 'branch --show-current') {
      return { status: 0, stdout: 'issue/test\n', stderr: '' };
    }
    if (args.join(' ') === 'merge-base HEAD upstream/develop') {
      return { status: 0, stdout: 'base123\n', stderr: '' };
    }
    if (args.join(' ') === 'status --short --untracked-files=no') {
      return { status: 0, stdout: '', stderr: '' };
    }
    if (args.join(' ') === 'diff --cached --name-only --diff-filter=ACMRT') {
      return { status: 1, stdout: '', stderr: 'fatal: bad index\n' };
    }
    throw new Error(`Unexpected git command: ${args.join(' ')}`);
  };

  assert.throws(
    () => collectReviewContext({ repoRoot, mode: 'staged', maxFiles: 5, maxDiffBytes: 1024, runGitFn }),
    /fatal: bad index/
  );
});

test('collectReviewContext fails closed when head-mode changed-file discovery errors', () => {
  const repoRoot = 'C:/repo';
  const runGitFn = (candidateRepoRoot, args) => {
    assert.equal(candidateRepoRoot, repoRoot);
    const key = args.join(' ');
    if (key === 'rev-parse HEAD') {
      return { status: 0, stdout: 'abc123\n', stderr: '' };
    }
    if (key === 'branch --show-current') {
      return { status: 0, stdout: 'issue/test\n', stderr: '' };
    }
    if (key === 'merge-base HEAD upstream/develop') {
      return { status: 0, stdout: 'base123\n', stderr: '' };
    }
    if (key === 'status --short --untracked-files=no') {
      return { status: 0, stdout: '', stderr: '' };
    }
    if (key === 'merge-base HEAD upstream/develop' || key === 'merge-base HEAD origin/develop') {
      return { status: 0, stdout: 'base123\n', stderr: '' };
    }
    if (key === 'merge-base HEAD origin/develop') {
      return { status: 0, stdout: 'base123\n', stderr: '' };
    }
    if (key === 'merge-base HEAD base123') {
      return { status: 0, stdout: 'base123\n', stderr: '' };
    }
    if (key === 'diff --name-only --diff-filter=ACMRT base123..HEAD') {
      return { status: 1, stdout: '', stderr: 'fatal: bad revision\n' };
    }
    if (key === 'rev-parse HEAD~1') {
      return { status: 0, stdout: 'base123\n', stderr: '' };
    }
    throw new Error(`Unexpected git command: ${key}`);
  };

  assert.throws(
    () => collectReviewContext({ repoRoot, mode: 'head', maxFiles: 5, maxDiffBytes: 1024, runGitFn }),
    /fatal: bad revision/
  );
});

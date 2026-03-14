import test from 'node:test';
import assert from 'node:assert/strict';
import os from 'node:os';
import path from 'node:path';
import { mkdir, mkdtemp, readFile, writeFile } from 'node:fs/promises';
import { spawnSync } from 'node:child_process';
import {
  LOCAL_COLLAB_ORCHESTRATOR_SCHEMA,
  parseArgs,
  resolvePhaseProviderSelection,
  runLocalCollaborationPhase
} from '../run-phase.mjs';

async function createGitRepo() {
  const repoRoot = await mkdtemp(path.join(os.tmpdir(), 'local-collab-orchestrator-'));
  spawnSync('git', ['init', '--initial-branch=develop'], { cwd: repoRoot, encoding: 'utf8' });
  await writeFile(path.join(repoRoot, 'README.md'), '# test\n', 'utf8');
  await mkdir(path.join(repoRoot, 'tools', 'policy'), { recursive: true });
  await writeFile(
    path.join(repoRoot, 'tools', 'policy', 'branch-classes.json'),
    JSON.stringify({
      schema: 'branch-classes/v1',
      schemaVersion: '1.0.0',
      upstreamRepository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      repositoryPlanes: [
        {
          id: 'upstream',
          repositories: ['LabVIEW-Community-CI-CD/compare-vi-cli-action'],
          developBranch: 'develop',
          developClass: 'upstream-integration',
          laneBranchPrefix: 'issue/',
          purpose: 'Canonical integration plane.',
          personas: ['daemon']
        },
        {
          id: 'origin',
          repositories: ['LabVIEW-Community-CI-CD/compare-vi-cli-action-fork'],
          developBranch: 'develop',
          developClass: 'fork-mirror-develop',
          laneBranchPrefix: 'issue/origin-',
          purpose: 'Org review plane.',
          personas: ['copilot-cli']
        },
        {
          id: 'personal',
          repositories: ['svelderrainruiz/compare-vi-cli-action'],
          developBranch: 'develop',
          developClass: 'fork-mirror-develop',
          laneBranchPrefix: 'issue/personal-',
          purpose: 'Personal authoring plane.',
          personas: ['codex', 'codex-cli']
        }
      ],
      classes: [
        {
          id: 'upstream-integration',
          repositoryRoles: ['upstream'],
          branchPatterns: ['develop'],
          purpose: 'Canonical integration branch.',
          prSourceAllowed: false,
          prTargetAllowed: true,
          mergePolicy: 'merge-queue-squash'
        },
        {
          id: 'fork-mirror-develop',
          repositoryRoles: ['fork'],
          branchPatterns: ['develop'],
          purpose: 'Mirror copy of upstream develop.',
          prSourceAllowed: false,
          prTargetAllowed: false,
          mergePolicy: 'mirror-only'
        },
        {
          id: 'lane',
          repositoryRoles: ['upstream', 'fork'],
          branchPatterns: ['issue/*'],
          purpose: 'Short-lived implementation branches.',
          prSourceAllowed: true,
          prTargetAllowed: false,
          mergePolicy: 'n/a'
        }
      ],
      allowedTransitions: [
        {
          from: 'lane',
          action: 'promote',
          to: 'upstream-integration',
          via: 'pull-request'
        }
      ],
      planeTransitions: [
        {
          from: 'personal',
          action: 'review',
          to: 'origin',
          via: 'pull-request',
          branchClass: 'lane'
        }
      ]
    }, null, 2),
    'utf8'
  );
  spawnSync('git', ['add', 'README.md'], { cwd: repoRoot, encoding: 'utf8' });
  spawnSync(
    'git',
    ['-c', 'user.name=Test User', '-c', 'user.email=test@example.com', 'commit', '-m', 'initial'],
    { cwd: repoRoot, encoding: 'utf8' }
  );
  return repoRoot;
}

test('parseArgs preserves delegate args for daemon phase', () => {
  const parsed = parseArgs([
    'node',
    'run-phase.mjs',
    '--phase',
    'daemon',
    '--repo-root',
    '/tmp/repo',
    '--orchestrator-receipt-path',
    'tests/results/_agent/local-collab/orchestrator/daemon.json',
    '--providers',
    'copilot-cli,simulation',
    '--receipt-path',
    'tests/results/docker-tools-parity/review-loop-receipt.json',
    '--skip-actionlint'
  ]);

  assert.equal(parsed.phase, 'daemon');
  assert.equal(parsed.repoRoot, '/tmp/repo');
  assert.deepEqual(parsed.providers, ['copilot-cli', 'simulation']);
  assert.deepEqual(parsed.delegateArgs, [
    '--receipt-path',
    'tests/results/docker-tools-parity/review-loop-receipt.json',
    '--skip-actionlint'
  ]);
});

test('resolvePhaseProviderSelection prefers explicit, then phase, then shared overrides', () => {
  assert.deepEqual(
    resolvePhaseProviderSelection('pre-commit', { PRECOMMIT_AGENT_REVIEW_PROVIDERS: 'simulation', HOOKS_AGENT_REVIEW_PROVIDERS: 'copilot-cli' }, ['codex-cli']),
    { selectionSource: 'explicit', providers: ['codex-cli'] }
  );
  assert.deepEqual(
    resolvePhaseProviderSelection('pre-push', { PREPUSH_AGENT_REVIEW_PROVIDERS: 'simulation', HOOKS_AGENT_REVIEW_PROVIDERS: 'copilot-cli' }),
    { selectionSource: 'PREPUSH_AGENT_REVIEW_PROVIDERS', providers: ['simulation'] }
  );
  assert.deepEqual(
    resolvePhaseProviderSelection('daemon', { HOOKS_AGENT_REVIEW_PROVIDERS: 'copilot-cli,simulation' }),
    { selectionSource: 'HOOKS_AGENT_REVIEW_PROVIDERS', providers: ['copilot-cli', 'simulation'] }
  );
});

test('resolvePhaseProviderSelection defaults hosted hook phases to simulation when no explicit override is present', () => {
  assert.deepEqual(
    resolvePhaseProviderSelection('pre-commit', { GITHUB_ACTIONS: 'true' }),
    { selectionSource: 'github-actions-default', providers: ['simulation'] }
  );
  assert.deepEqual(
    resolvePhaseProviderSelection('pre-push', { GITHUB_ACTIONS: 'true' }),
    { selectionSource: 'github-actions-default', providers: ['simulation'] }
  );
  assert.deepEqual(
    resolvePhaseProviderSelection('daemon', { GITHUB_ACTIONS: 'true' }),
    { selectionSource: 'default-empty', providers: [] }
  );
});

test('runLocalCollaborationPhase writes deterministic daemon orchestrator receipts', async () => {
  const repoRoot = await createGitRepo();
  const result = await runLocalCollaborationPhase({
    phase: 'daemon',
    repoRoot,
    delegateArgs: ['--receipt-path', 'tests/results/docker-tools-parity/review-loop-receipt.json'],
    delegateFns: {
      daemon: async () => ({
        exitCode: 0,
        stdout: '{"status":"passed"}',
        stderr: ''
      })
    }
  });

  assert.equal(result.exitCode, 0);
  assert.equal(result.receipt.schema, LOCAL_COLLAB_ORCHESTRATOR_SCHEMA);
  assert.equal(result.receipt.phase, 'daemon');
  assert.equal(result.receipt.forkPlane, 'upstream');
  assert.equal(result.receipt.persona, 'daemon');
  assert.equal(result.receipt.executionPlane, 'docker');
  assert.equal(result.receipt.selectionSource, 'default-empty');
  assert.deepEqual(result.receipt.providers, []);
  assert.equal(result.receipt.branchModel.branchName, 'develop');
  assert.equal(result.receipt.branchModel.plane, null);
  assert.match(result.receipt.delegate.command.join(' '), /tools\/priority\/docker-desktop-review-loop\.mjs/);
  assert.equal(result.receipt.ledger.receiptId, `daemon:${result.receipt.headSha}`);

  const persisted = JSON.parse(await readFile(result.receiptPath, 'utf8'));
  assert.equal(persisted.schema, LOCAL_COLLAB_ORCHESTRATOR_SCHEMA);
  assert.equal(persisted.phase, 'daemon');
  assert.equal(persisted.status, 'passed');

  const ledgerReceipt = JSON.parse(await readFile(result.ledgerReceiptPath, 'utf8'));
  assert.equal(ledgerReceipt.phase, 'daemon');
  assert.equal(ledgerReceipt.headSha, result.receipt.headSha);
  assert.equal(ledgerReceipt.executionPlane, 'docker');
  assert.equal(ledgerReceipt.providerId, 'none');
});

test('runLocalCollaborationPhase runs daemon agent review after Docker parity passes', async () => {
  const repoRoot = await createGitRepo();
  const result = await runLocalCollaborationPhase({
    phase: 'daemon',
    repoRoot,
    providers: ['simulation'],
    delegateArgs: ['--receipt-path', 'tests/results/docker-tools-parity/review-loop-receipt.json'],
    delegateFns: {
      daemon: async () => ({
        exitCode: 0,
        stdout: JSON.stringify({
          status: 'passed',
          source: 'docker-desktop-review-loop',
          reason: 'Docker/Desktop review loop passed.',
          receiptPath: 'tests/results/docker-tools-parity/review-loop-receipt.json',
          currentHeadSha: 'head-sha',
          receiptHeadSha: 'head-sha',
          receiptFreshForHead: true,
          requestedCoverageSatisfied: true,
          requestedCoverageReason: 'coverage ok',
          requestedCoverageMissingChecks: [],
          receipt: {
            overall: {
              status: 'passed',
              message: ''
            }
          }
        }),
        stderr: ''
      })
    },
    invokeAgentReviewPolicyFn: () => ({
      exitCode: 0,
      receipt: {
        overall: {
          status: 'passed',
          actionableFindingCount: 0,
          message: 'Daemon local agent review providers passed.'
        },
        providerSelection: {
          selectionSource: 'explicit-request'
        },
        requestedProviders: ['simulation']
      }
    })
  });

  assert.equal(result.exitCode, 0);
  assert.equal(result.receipt.delegate.agentReview.receiptStatus, 'passed');
  assert.deepEqual(result.receipt.delegate.agentReview.requestedProviders, ['simulation']);
  const daemonStdout = JSON.parse(result.stdout);
  assert.equal(daemonStdout.source, 'local-collab-daemon-review');
  assert.equal(daemonStdout.status, 'passed');
  assert.equal(daemonStdout.agentReview.receiptStatus, 'passed');
  assert.deepEqual(daemonStdout.agentReview.requestedProviders, ['simulation']);
});

test('runLocalCollaborationPhase skips daemon agent review when Docker parity fails', async () => {
  const repoRoot = await createGitRepo();
  let invokedAgentReview = false;
  const result = await runLocalCollaborationPhase({
    phase: 'daemon',
    repoRoot,
    providers: ['simulation'],
    delegateFns: {
      daemon: async () => ({
        exitCode: 1,
        stdout: JSON.stringify({
          status: 'failed',
          source: 'docker-desktop-review-loop',
          reason: 'Docker/Desktop review loop failed.'
        }),
        stderr: 'docker failed'
      })
    },
    invokeAgentReviewPolicyFn: () => {
      invokedAgentReview = true;
      return {
        exitCode: 0,
        receipt: {
          overall: {
            status: 'passed'
          }
        }
      };
    }
  });

  assert.equal(result.exitCode, 1);
  assert.equal(invokedAgentReview, false);
  assert.equal(result.receipt.delegate.agentReview, null);
});

test('runLocalCollaborationPhase records codex authoring receipts for post-commit', async () => {
  const repoRoot = await createGitRepo();
  await writeFile(path.join(repoRoot, 'README.md'), '# changed\n', 'utf8');
  spawnSync('git', ['add', 'README.md'], { cwd: repoRoot, encoding: 'utf8' });
  spawnSync(
    'git',
    ['-c', 'user.name=Test User', '-c', 'user.email=test@example.com', 'commit', '-m', 'second'],
    { cwd: repoRoot, encoding: 'utf8' }
  );

  const result = await runLocalCollaborationPhase({
    phase: 'post-commit',
    repoRoot
  });

  assert.equal(result.exitCode, 0);
  assert.equal(result.receipt.phase, 'post-commit');
  assert.equal(result.receipt.forkPlane, 'personal');
  assert.equal(result.receipt.persona, 'codex');
  assert.equal(result.receipt.executionPlane, 'windows-host');
  assert.equal(result.receipt.branchModel.branchName, 'develop');
  assert.equal(result.receipt.branchModel.plane, null);
  assert.equal(result.receipt.commitCreated, true);
  assert.deepEqual(result.receipt.filesTouched, ['README.md']);
  assert.match(result.receipt.delegate.summaryPath, /tests[\\/]results[\\/]_hooks[\\/]post-commit\.json$/);

  const ledgerReceipt = JSON.parse(await readFile(result.ledgerReceiptPath, 'utf8'));
  assert.equal(ledgerReceipt.phase, 'post-commit');
  assert.equal(ledgerReceipt.commitCreated, true);
  assert.equal(ledgerReceipt.executionPlane, 'windows-host');
  assert.deepEqual(ledgerReceipt.filesTouched, ['README.md']);
});

test('runLocalCollaborationPhase gates pre-commit on local agent review and records receipt linkage', async () => {
  const repoRoot = await createGitRepo();
  await writeFile(path.join(repoRoot, 'notes.txt'), 'hello\n', 'utf8');
  spawnSync('git', ['add', 'notes.txt'], { cwd: repoRoot, encoding: 'utf8' });

  const result = await runLocalCollaborationPhase({
    phase: 'pre-commit',
    repoRoot,
    providers: ['simulation'],
    invokeAgentReviewPolicyFn: () => ({
      exitCode: 0,
      receipt: {
        overall: {
          status: 'passed',
          actionableFindingCount: 0
        },
        providerSelection: {
          selectionSource: 'explicit-request'
        },
        requestedProviders: ['simulation']
      }
    })
  });

  assert.equal(result.exitCode, 0);
  assert.equal(result.receipt.phase, 'pre-commit');
  assert.equal(result.receipt.delegate.agentReview.receiptPath, 'tests/results/_hooks/pre-commit-agent-review-policy.json');
  assert.equal(result.receipt.delegate.agentReview.receiptStatus, 'passed');
  assert.deepEqual(result.receipt.delegate.agentReview.requestedProviders, ['simulation']);
  assert.equal(result.receipt.branchModel.branchName, 'develop');
  assert.equal(result.receipt.branchModel.plane, null);

  const hookSummary = JSON.parse(await readFile(result.receipt.delegate.summaryPath, 'utf8'));
  const reviewStep = hookSummary.steps.find((step) => step.name === 'agent-review-policy');
  assert.ok(reviewStep);
  assert.equal(reviewStep.status, 'ok');
  assert.equal(reviewStep.rawExitCode, 0);
  assert.match(reviewStep.note, /pre-commit-agent-review-policy\.json/);
});

test('runLocalCollaborationPhase defaults hosted pre-commit reviews to simulation', async () => {
  const repoRoot = await createGitRepo();
  await mkdir(path.join(repoRoot, 'tmp', 'hooks'), { recursive: true });
  await writeFile(path.join(repoRoot, 'tmp', 'hooks', 'sample.txt'), 'hook parity sample\n', 'utf8');
  spawnSync('git', ['add', 'tmp/hooks/sample.txt'], { cwd: repoRoot, encoding: 'utf8' });

  let observedSelection = null;
  const result = await runLocalCollaborationPhase({
    phase: 'pre-commit',
    repoRoot,
    env: {
      ...process.env,
      GITHUB_ACTIONS: 'true'
    },
    invokeAgentReviewPolicyFn: ({ providerSelection }) => {
      observedSelection = providerSelection;
      return {
        exitCode: 0,
        receipt: {
          overall: {
            status: 'passed',
            actionableFindingCount: 0
          },
          providerSelection: {
            selectionSource: 'github-actions-default'
          },
          requestedProviders: ['simulation']
        }
      };
    }
  });

  assert.equal(result.exitCode, 0);
  assert.deepEqual(observedSelection, {
    selectionSource: 'github-actions-default',
    providers: ['simulation']
  });
  assert.equal(result.receipt.delegate.agentReview.selectionSource, 'github-actions-default');
  assert.deepEqual(result.receipt.delegate.agentReview.requestedProviders, ['simulation']);
});

test('runLocalCollaborationPhase infers the origin hook plane from the lane branch prefix', async () => {
  const repoRoot = await createGitRepo();
  spawnSync('git', ['checkout', '-b', 'issue/origin-1084-review-lane'], { cwd: repoRoot, encoding: 'utf8' });
  await writeFile(path.join(repoRoot, 'notes.txt'), 'lane\n', 'utf8');
  spawnSync('git', ['add', 'notes.txt'], { cwd: repoRoot, encoding: 'utf8' });

  const result = await runLocalCollaborationPhase({
    phase: 'pre-commit',
    repoRoot,
    providers: ['simulation'],
    invokeAgentReviewPolicyFn: () => ({
      exitCode: 0,
      receipt: {
        overall: {
          status: 'passed',
          actionableFindingCount: 0
        },
        providerSelection: {
          selectionSource: 'explicit-request'
        },
        requestedProviders: ['simulation']
      }
    })
  });

  assert.equal(result.exitCode, 0);
  assert.equal(result.receipt.forkPlane, 'origin');
  assert.equal(result.receipt.branchModel.branchName, 'issue/origin-1084-review-lane');
  assert.equal(result.receipt.branchModel.plane, 'origin');
  assert.equal(result.receipt.branchModel.laneBranchPrefix, 'issue/origin-');

  const ledgerReceipt = JSON.parse(await readFile(result.ledgerReceiptPath, 'utf8'));
  assert.equal(ledgerReceipt.forkPlane, 'origin');
  assert.equal(ledgerReceipt.metadata.branchModel.plane, 'origin');
});

test('runLocalCollaborationPhase fails closed when an explicit hook plane conflicts with the lane branch prefix', async () => {
  const repoRoot = await createGitRepo();
  spawnSync('git', ['checkout', '-b', 'issue/origin-1084-review-lane'], { cwd: repoRoot, encoding: 'utf8' });

  await assert.rejects(
    () =>
      runLocalCollaborationPhase({
        phase: 'pre-commit',
        repoRoot,
        forkPlane: 'personal',
        providers: ['simulation'],
        invokeAgentReviewPolicyFn: () => ({
          exitCode: 0,
          receipt: {
            overall: {
              status: 'passed',
              actionableFindingCount: 0
            },
            providerSelection: {
              selectionSource: 'explicit-request'
            },
            requestedProviders: ['simulation']
          }
        })
      }),
    /conflicts with branch plane 'origin'/
  );
});

test('runLocalCollaborationPhase keeps pre-push non-blocking in local warn mode when local agent review fails', async () => {
  const repoRoot = await createGitRepo();

  const result = await runLocalCollaborationPhase({
    phase: 'pre-push',
    repoRoot,
    providers: ['simulation'],
    invokeAgentReviewPolicyFn: () => ({
      exitCode: 1,
      receipt: {
        overall: {
          status: 'failed',
          actionableFindingCount: 1
        },
        providerSelection: {
          selectionSource: 'explicit-request'
        },
        requestedProviders: ['simulation']
      }
    }),
    env: {
      ...process.env,
      HOOKS_ENFORCE: 'warn'
    }
  });

  assert.equal(result.exitCode, 0);
  assert.equal(result.receipt.phase, 'pre-push');
  assert.equal(result.receipt.delegate.agentReview.receiptStatus, 'failed');
  assert.deepEqual(result.receipt.delegate.agentReview.requestedProviders, ['simulation']);

  const hookSummary = JSON.parse(await readFile(result.receipt.delegate.summaryPath, 'utf8'));
  const reviewStep = hookSummary.steps.find((step) => step.name === 'agent-review-policy');
  assert.ok(reviewStep);
  assert.equal(reviewStep.status, 'warn');
  assert.equal(reviewStep.rawExitCode, 1);
  assert.match(reviewStep.note, /converted to warning by HOOKS_ENFORCE=warn/);
  assert.equal(hookSummary.steps.some((step) => step.name === 'pre-push-checks'), true);
});

test('runLocalCollaborationPhase blocks pre-push before heavy checks in fail mode when local agent review fails', async () => {
  const repoRoot = await createGitRepo();

  const result = await runLocalCollaborationPhase({
    phase: 'pre-push',
    repoRoot,
    providers: ['simulation'],
    invokeAgentReviewPolicyFn: () => ({
      exitCode: 1,
      receipt: {
        overall: {
          status: 'failed',
          actionableFindingCount: 1
        },
        providerSelection: {
          selectionSource: 'explicit-request'
        },
        requestedProviders: ['simulation']
      }
    }),
    env: {
      ...process.env,
      HOOKS_ENFORCE: 'fail'
    }
  });

  assert.equal(result.exitCode, 1);
  const hookSummary = JSON.parse(await readFile(result.receipt.delegate.summaryPath, 'utf8'));
  const reviewStep = hookSummary.steps.find((step) => step.name === 'agent-review-policy');
  assert.ok(reviewStep);
  assert.equal(reviewStep.status, 'failed');
  assert.equal(reviewStep.rawExitCode, 1);
  assert.match(
    hookSummary.notes.join('\n'),
    /Skipped core pre-push checks because local agent review failed/
  );
  assert.equal(hookSummary.steps.some((step) => step.name === 'pre-push-checks'), false);
});

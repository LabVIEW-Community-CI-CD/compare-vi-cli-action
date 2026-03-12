#!/usr/bin/env node

import test from 'node:test';
import assert from 'node:assert/strict';

import {
  buildCodexTurnPrompt,
  buildPrReadyArgs,
  buildUnattendedCommandEnv,
  planPullRequestReviewCycle
} from '../run-delivery-turn-with-codex.mjs';

test('buildCodexTurnPrompt includes bounded delivery context and helper surfaces', () => {
  const prompt = buildCodexTurnPrompt({
    repoRoot: '/work/repo',
    workDir: '/work/repo/.runtime-worktrees/example/origin-1012',
    taskPacket: {
      repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      objective: {
        summary: 'Advance issue #1012: wire the canonical delivery broker'
      },
      branch: {
        name: 'issue/origin-1012-wire-canonical-delivery-broker'
      },
      pullRequest: {
        url: null
      },
      helperSurface: {
        preferred: ['node tools/npm/run-script.mjs priority:pr'],
        fallbacks: ['gh pr create --body-file <path>']
      },
      evidence: {
        lane: {
          workerCheckoutPath: '/work/repo/.runtime-worktrees/example/origin-1012'
        },
        delivery: {
          selectedIssue: {
            number: 1012
          },
          standingIssue: {
            number: 1010
          },
          turnBudget: {
            maxMinutes: 20,
            maxToolCalls: 12
          },
          relevantFiles: ['tools/priority/runtime-supervisor.mjs']
        }
      }
    }
  });

  assert.match(prompt, /Advance issue #1012: wire the canonical delivery broker/);
  assert.match(prompt, /Working directory: \/work\/repo\/\.runtime-worktrees\/example\/origin-1012/);
  assert.match(prompt, /Selected issue: #1012/);
  assert.match(prompt, /Standing issue\/epic: #1010/);
  assert.match(prompt, /priority:pr/);
  assert.match(prompt, /runtime-supervisor\.mjs/);
  assert.match(prompt, /All automation-authored PRs begin as drafts/i);
  assert.match(prompt, /broker will manage draft\/ready transitions/i);
  assert.match(prompt, /returning only JSON/i);
});

test('buildUnattendedCommandEnv forces non-interactive git and gh defaults', () => {
  const env = buildUnattendedCommandEnv({
    PATH: '/tmp/bin',
    GIT_TERMINAL_PROMPT: '',
    GH_PROMPT_DISABLED: '',
    GCM_INTERACTIVE: ''
  });

  assert.equal(env.PATH, '/tmp/bin');
  assert.equal(env.GIT_TERMINAL_PROMPT, '0');
  assert.equal(env.GH_PROMPT_DISABLED, '1');
  assert.equal(env.GCM_INTERACTIVE, 'Never');
});

test('buildUnattendedCommandEnv preserves explicit non-default settings', () => {
  const env = buildUnattendedCommandEnv({
    GIT_TERMINAL_PROMPT: '1',
    GH_PROMPT_DISABLED: '0',
    GCM_INTERACTIVE: 'Auto'
  });

  assert.equal(env.GIT_TERMINAL_PROMPT, '1');
  assert.equal(env.GH_PROMPT_DISABLED, '0');
  assert.equal(env.GCM_INTERACTIVE, 'Auto');
});

test('buildPrReadyArgs uses gh pr ready and --undo for broker-managed draft transitions', () => {
  assert.deepEqual(
    buildPrReadyArgs({
      repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      pullRequestNumber: 1015,
      ready: true
    }),
    ['pr', 'ready', '1015', '--repo', 'LabVIEW-Community-CI-CD/compare-vi-cli-action']
  );

  assert.deepEqual(
    buildPrReadyArgs({
      repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      pullRequestNumber: 1015,
      ready: false
    }),
    ['pr', 'ready', '1015', '--repo', 'LabVIEW-Community-CI-CD/compare-vi-cli-action', '--undo']
  );
});

test('planPullRequestReviewCycle drafts an existing ready PR before mutation and returns it to ready for a fresh Copilot review after a new head is pushed', () => {
  const plan = planPullRequestReviewCycle({
    initialPullRequest: {
      number: 1015,
      isDraft: false
    },
    finalPullRequest: {
      number: 1015,
      isDraft: true
    },
    startHead: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
    endHead: 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
    codexSucceeded: true
  });

  assert.deepEqual(plan, {
    draftBeforeMutation: true,
    readyAfterMutation: true,
    restoreReadyWithoutMutation: false,
    freshCopilotReviewExpected: true,
    headChanged: true,
    initialPullRequestNumber: 1015,
    finalPullRequestNumber: 1015
  });
});

test('planPullRequestReviewCycle treats a new draft PR as waiting on the first broker-managed Copilot review after it returns to ready', () => {
  const plan = planPullRequestReviewCycle({
    initialPullRequest: null,
    finalPullRequest: {
      number: 1016,
      isDraft: true
    },
    startHead: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
    endHead: 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
    codexSucceeded: true
  });

  assert.deepEqual(plan, {
    draftBeforeMutation: false,
    readyAfterMutation: true,
    restoreReadyWithoutMutation: false,
    freshCopilotReviewExpected: true,
    headChanged: true,
    initialPullRequestNumber: null,
    finalPullRequestNumber: 1016
  });
});

test('planPullRequestReviewCycle restores a previously ready PR without demanding a fresh Copilot review when the broker made no new commit', () => {
  const plan = planPullRequestReviewCycle({
    initialPullRequest: {
      number: 1015,
      isDraft: false
    },
    finalPullRequest: {
      number: 1015,
      isDraft: true
    },
    startHead: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
    endHead: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
    codexSucceeded: false
  });

  assert.deepEqual(plan, {
    draftBeforeMutation: true,
    readyAfterMutation: true,
    restoreReadyWithoutMutation: true,
    freshCopilotReviewExpected: false,
    headChanged: false,
    initialPullRequestNumber: 1015,
    finalPullRequestNumber: 1015
  });
});

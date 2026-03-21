#!/usr/bin/env node

import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import {
  buildCodexTurnPrompt,
  buildPrReadyArgs,
  buildPullRequestTimelineArgs,
  selectAuthoritativeDraftTransition,
  buildUnattendedCommandEnv,
  planPullRequestReviewCycle,
  waitForAuthoritativeDraftTransition
} from '../run-delivery-turn-with-codex.mjs';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..', '..');

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
          liveAgentModelSelection: {
            mode: 'recommend-only',
            currentProvider: {
              providerId: 'local-codex',
              currentModel: 'gpt-5.4',
              currentReasoningEffort: 'xhigh',
              selectedModel: 'gpt-5.4',
              selectedReasoningEffort: 'xhigh',
              action: 'stay',
              confidence: 'medium',
              reasonCodes: ['stable-current-model']
            }
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
  assert.match(prompt, /Model recommendation mode: recommend-only/);
  assert.match(prompt, /Provider model recommendation: gpt-5\.4\/xhigh/);
  assert.match(prompt, /Recommendation reasons: stable-current-model/);
  assert.match(prompt, /priority:pr/);
  assert.match(prompt, /runtime-supervisor\.mjs/);
  assert.match(prompt, /All automation-authored PRs begin as drafts/i);
  assert.match(prompt, /only the outer delivery layer restores ready for review/i);
  assert.match(prompt, /leave the lane in draft review phase while ensuring CI is green/i);
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

test('buildPullRequestTimelineArgs targets the REST issue timeline for PR transition evidence', () => {
  assert.deepEqual(
    buildPullRequestTimelineArgs({
      repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      pullRequestNumber: 1131
    }),
    [
      'api',
      'repos/LabVIEW-Community-CI-CD/compare-vi-cli-action/issues/1131/timeline',
      '-H',
      'Accept: application/vnd.github+json',
      '-f',
      'per_page=50'
    ]
  );
});

test('selectAuthoritativeDraftTransition ignores stale draft events and picks the new transition', () => {
  const staleOnly = selectAuthoritativeDraftTransition({
    ready: false,
    previousEventId: 11,
    timelineEvents: [
      {
        id: 11,
        event: 'converted_to_draft',
        created_at: '2026-03-14T09:00:00Z',
        actor: { login: 'bot' }
      }
    ]
  });
  assert.equal(staleOnly, null);

  const fresh = selectAuthoritativeDraftTransition({
    ready: false,
    previousEventId: 11,
    timelineEvents: [
      {
        id: 11,
        event: 'converted_to_draft',
        created_at: '2026-03-14T09:00:00Z',
        actor: { login: 'bot' }
      },
      {
        id: 12,
        event: 'converted_to_draft',
        created_at: '2026-03-14T09:00:05Z',
        actor: { login: 'bot' }
      }
    ]
  });

  assert.deepEqual(fresh, {
    ok: true,
    event: 'converted_to_draft',
    eventId: 12,
    createdAt: '2026-03-14T09:00:05Z',
    actor: 'bot',
    authoritativeIsDraft: true
  });
});

test('waitForAuthoritativeDraftTransition polls until the ready event appears', async () => {
  let reads = 0;
  const result = await waitForAuthoritativeDraftTransition({
    ready: true,
    previousEventId: 20,
    transitionStartedAt: '2026-03-14T09:00:00Z',
    pollAttempts: 3,
    pollDelayMs: 0,
    sleepFn: async () => {},
    readTimelineEventsFn: async () => {
      reads += 1;
      if (reads === 1) {
        return [
          {
            id: 20,
            event: 'ready_for_review',
            created_at: '2026-03-14T08:59:55Z',
            actor: { login: 'bot' }
          }
        ];
      }
      return [
        {
          id: 21,
          event: 'ready_for_review',
          created_at: '2026-03-14T09:00:02Z',
          actor: { login: 'bot' }
        }
      ];
    }
  });

  assert.deepEqual(result, {
    ok: true,
    event: 'ready_for_review',
    eventId: 21,
    createdAt: '2026-03-14T09:00:02Z',
    actor: 'bot',
    authoritativeIsDraft: false,
    attemptsUsed: 2
  });
});

test('waitForAuthoritativeDraftTransition fails loudly when no matching timeline evidence arrives', async () => {
  const result = await waitForAuthoritativeDraftTransition({
    ready: false,
    transitionStartedAt: '2026-03-14T09:00:00Z',
    pollAttempts: 2,
    pollDelayMs: 0,
    sleepFn: async () => {},
    readTimelineEventsFn: async () => []
  });

  assert.equal(result.ok, false);
  assert.equal(result.event, 'converted_to_draft');
  assert.equal(result.attemptsUsed, 2);
  assert.match(result.reason, /authoritative draft transition evidence/i);
});

test('planPullRequestReviewCycle leaves an existing ready PR in draft for outer-layer ready restoration under the draft-only strategy', () => {
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
    readyAfterMutation: false,
    restoreReadyWithoutMutation: false,
    readyDeferredToOuterLayer: true,
    freshCopilotReviewExpected: false,
    headChanged: true,
    initialPullRequestNumber: 1015,
    finalPullRequestNumber: 1015
  });
});

test('planPullRequestReviewCycle leaves a new draft PR draft for outer-layer ready restoration', () => {
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
    readyAfterMutation: false,
    restoreReadyWithoutMutation: false,
    readyDeferredToOuterLayer: true,
    freshCopilotReviewExpected: false,
    headChanged: true,
    initialPullRequestNumber: null,
    finalPullRequestNumber: 1016
  });
});

test('planPullRequestReviewCycle leaves a previously ready PR draft even when the broker made no new commit under the draft-only strategy', () => {
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
    readyAfterMutation: false,
    restoreReadyWithoutMutation: false,
    readyDeferredToOuterLayer: true,
    freshCopilotReviewExpected: false,
    headChanged: false,
    initialPullRequestNumber: 1015,
    finalPullRequestNumber: 1015
  });
});

test('runCodexDeliveryTurn plans review restoration from the original PR state, not the broker-forced draft clone', () => {
  const source = readFileSync(path.join(repoRoot, 'tools/priority/run-delivery-turn-with-codex.ts'), 'utf8');

  assert.match(
    source,
    /const reviewCycle = planPullRequestReviewCycle\(\{\s*initialPullRequest,\s*finalPullRequest: pullRequest,/s
  );
});

test('run-delivery-turn shim avoids static dist re-exports so clean runners can build before import resolution', () => {
  const source = readFileSync(path.join(repoRoot, 'tools/priority/run-delivery-turn-with-codex.mjs'), 'utf8');

  assert.doesNotMatch(source, /export \* from '\.\.\/\.\.\/dist\/tools\/priority\/run-delivery-turn-with-codex\.js'/);
  assert.match(source, /const imported = await import\(pathToFileURL\(distPath\)\.href\);/);
  assert.match(source, /export const buildPullRequestTimelineArgs = imported\.buildPullRequestTimelineArgs;/);
});

test('runCodexDeliveryTurn records broker-managed PR ready-state helper calls even when the gh command fails', () => {
  const source = readFileSync(path.join(repoRoot, 'tools/priority/run-delivery-turn-with-codex.ts'), 'utf8');

  assert.match(source, /if \(toDraft\.helperCall\) \{\s*brokerHelperCalls\.push\(toDraft\.helperCall\);/s);
  assert.match(source, /if \(toReady\.helperCall\) \{\s*brokerHelperCalls\.push\(toReady\.helperCall\);/s);
});

test('runCodexDeliveryTurn waits for authoritative timeline evidence instead of trusting immediate isDraft reads', () => {
  const source = readFileSync(path.join(repoRoot, 'tools/priority/run-delivery-turn-with-codex.ts'), 'utf8');

  assert.match(source, /await waitForAuthoritativeDraftTransition\(/);
  assert.match(source, /authoritative converted_to_draft timeline event/);
  assert.match(source, /could not verify the draft transition/i);
});

test('runCodexDeliveryTurn surfaces broker-managed draft transition failures and outer-layer ready deferral in receipt notes', () => {
  const source = readFileSync(path.join(repoRoot, 'tools/priority/run-delivery-turn-with-codex.ts'), 'utf8');

  assert.match(source, /brokerTransitionNotes = \[\]/);
  assert.match(source, /Broker failed to mark PR #\$\{initialPullRequest\.number\} as draft before mutation:/);
  assert.match(source, /Broker failed to mark PR #\$\{pullRequest\.number\} ready for review after mutation:/);
  assert.match(source, /brokerTransitionNotes = \[\],[\s\S]*noteParts = \[[\s\S]*brokerTransitionNotes\.map/s);
  assert.match(source, /Broker left the PR draft; the outer delivery layer must restore ready for review after local review and current-head draft-phase Copilot clearance\./);
});

test('runCodexDeliveryTurn marks forced waiting-review receipts with blockerClass review', () => {
  const source = readFileSync(path.join(repoRoot, 'tools/priority/run-delivery-turn-with-codex.ts'), 'utf8');

  assert.match(source, /const reviewWaitEnforced =[\s\S]*laneLifecycle === 'waiting-review'[\s\S]*readyDeferredToOuterLayer \|\| reviewCycle\?\.freshCopilotReviewExpected/s);
  assert.match(source, /const blockerClass = reviewWaitEnforced\s*\?\s*'review'/);
});

test('delivery agent retains local review loop audit helpers when watch receipts restore ready or draft state', () => {
  const source = readFileSync(path.join(repoRoot, 'tools/priority/delivery-agent.mjs'), 'utf8');

  assert.match(source, /let localReviewLoopHelperCalls = \[\];/);
  assert.match(source, /localReviewLoopHelperCalls = uniqueStrings\(/);
  assert.match(source, /helperCallsExecuted: uniqueStrings\(\[\.\.\.localReviewLoopHelperCalls, toReady\.helperCall\]\)/);
  assert.match(source, /helperCallsExecuted: uniqueStrings\(\[\.\.\.localReviewLoopHelperCalls, toDraft\.helperCall\]\)/);
  assert.match(source, /helperCallsExecuted: localReviewLoopHelperCalls,/);
});

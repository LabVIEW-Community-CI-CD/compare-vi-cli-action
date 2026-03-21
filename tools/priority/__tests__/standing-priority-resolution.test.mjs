#!/usr/bin/env node

import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, mkdir, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import {
  parseCliArgs,
  selectAutoStandingPriorityCandidate,
  selectAutoStandingPriorityCandidateForRepo,
  autoSelectStandingPriorityIssue,
  classifyNoStandingPriorityCondition,
  buildNoStandingPriorityReport,
  buildAutoPromotedStandingPriorityReport,
  buildMultipleStandingPriorityReport,
  buildNoStandingPriorityState,
  shouldRethrowStandingPriorityError,
  shouldContinueAfterAutoSelectLaneEmpty,
  determinePrioritySyncExitCode,
  isStandingPriorityCacheCandidate,
  resolveStandingPriorityLabels,
  resolveStandingPriorityRepositorySlug,
  resolveStandingPriorityFromSources,
  resolveUpstreamRepositorySlug,
  resolveStandingPriorityLookupPlan,
  resolveStandingPriorityForRepo,
  parseUpstreamIssuePointerFromBody,
  fetchIssue,
  hasOnlyBlockedConcreteIssuesBehindFallbackParent,
  computeNextPriorityCacheState,
  shouldPersistCacheUpdate,
  gitRoot
} from '../sync-standing-priority.mjs';

function buildExternalIssueStateFetcher(issueStates = {}) {
  const overrides = new Map(
    Object.entries(issueStates).map(([issueNumber, state]) => [Number.parseInt(issueNumber, 10), state])
  );

  return async (issueNumber) => {
    const state = overrides.get(issueNumber) ?? 'open';
    if (state instanceof Error) {
      throw state;
    }
    return {
      number: issueNumber,
      state
    };
  };
}

test('isStandingPriorityCacheCandidate requires OPEN state and matching standing label', () => {
  assert.equal(
    isStandingPriorityCacheCandidate({
      number: 42,
      state: 'OPEN',
      labels: ['bug', 'standing-priority']
    }),
    true
  );

  assert.equal(
    isStandingPriorityCacheCandidate({
      number: 42,
      state: 'CLOSED',
      labels: ['standing-priority']
    }),
    false
  );

  assert.equal(
    isStandingPriorityCacheCandidate({
      number: 42,
      state: 'OPEN',
      labels: ['bug']
    }),
    false
  );
});

test('resolveStandingPriorityFromSources uses cache only when lookups are unavailable and cache is valid', () => {
  const number = resolveStandingPriorityFromSources({
    ghOutcome: { status: 'unavailable', error: 'gh missing' },
    restOutcome: { status: 'error', error: 'network timeout' },
    standingPriorityLabels: ['fork-standing-priority', 'standing-priority'],
    cache: {
      number: 99,
      state: 'OPEN',
      labels: ['standing-priority']
    }
  });
  assert.equal(number, 99);
});

test('resolveStandingPriorityFromSources rejects stale cache when gh reports empty standing set', () => {
  assert.throws(
    () =>
      resolveStandingPriorityFromSources({
        ghOutcome: { status: 'empty' },
        restOutcome: { status: 'error', error: 'network timeout' },
        standingPriorityLabels: ['fork-standing-priority', 'standing-priority'],
        cache: {
          number: 1,
          state: 'OPEN',
          labels: ['standing-priority']
        }
      }),
    (err) => err?.code === 'NO_STANDING_PRIORITY'
  );
});

test('resolveStandingPriorityFromSources rejects stale cache when rest reports empty standing set', () => {
  assert.throws(
    () =>
      resolveStandingPriorityFromSources({
        ghOutcome: { status: 'error', error: 'gh unavailable' },
        restOutcome: { status: 'empty' },
        standingPriorityLabels: ['fork-standing-priority', 'standing-priority'],
        cache: {
          number: 1,
          state: 'OPEN',
          labels: ['standing-priority']
        }
      }),
    (err) => err?.code === 'NO_STANDING_PRIORITY'
  );
});

test('resolveStandingPriorityFromSources fails when only invalid cache remains', () => {
  assert.throws(
    () =>
      resolveStandingPriorityFromSources({
        ghOutcome: { status: 'unavailable', error: 'gh missing' },
        restOutcome: { status: 'error', error: 'network timeout' },
        standingPriorityLabels: ['fork-standing-priority', 'standing-priority'],
        cache: {
          number: 1,
          state: 'CLOSED',
          labels: ['standing-priority']
        }
      }),
    /Unable to resolve standing-priority issue number/
  );
});

test('buildNoStandingPriorityState clears router/cache deterministically', () => {
  const state = buildNoStandingPriorityState(
    {
      number: 12,
      title: 'Old',
      state: 'OPEN',
      labels: ['standing-priority']
    },
    'No open issue found with labels: `fork-standing-priority`, `standing-priority`.',
    '2026-03-03T03:10:00.000Z',
    ['fork-standing-priority', 'standing-priority']
  );

  assert.equal(state.clearedRouter.issue, null);
  assert.deepEqual(state.clearedRouter.actions, []);
  assert.equal(state.clearedCache.number, null);
  assert.equal(state.clearedCache.state, 'NONE');
  assert.equal(
    state.clearedCache.lastFetchError,
    'No open issue found with labels: `fork-standing-priority`, `standing-priority`.'
  );
  assert.equal(state.clearedCache.noStandingReason, 'label-missing');
  assert.equal(state.result.fetchSource, 'none');
  assert.equal(state.result.noStandingReason, 'label-missing');
});

test('resolveStandingPriorityLabels prefers fork-standing-priority when configured upstream differs', () => {
  const labels = resolveStandingPriorityLabels(
    '/tmp/repo',
    'fork-owner/compare-vi-cli-action',
    {
      AGENT_PRIORITY_UPSTREAM_REPOSITORY: 'upstream-owner/compare-vi-cli-action'
    }
  );
  assert.deepEqual(labels, ['fork-standing-priority', 'standing-priority']);
});

test('resolveStandingPriorityLabels defaults to standing-priority when upstream matches current repository', () => {
  const currentSlug = 'repo-owner/compare-vi-cli-action';
  const labels = resolveStandingPriorityLabels(
    '/tmp/repo',
    currentSlug,
    {
      AGENT_PRIORITY_UPSTREAM_REPOSITORY: currentSlug
    }
  );
  assert.deepEqual(labels, ['standing-priority']);
});

test('resolveStandingPriorityLabels honors explicit env override order', () => {
  const labels = resolveStandingPriorityLabels('/tmp/repo', null, {
    AGENT_STANDING_PRIORITY_LABELS: 'custom-one, custom-two, custom-one'
  });
  assert.deepEqual(labels, ['custom-one', 'custom-two']);
});

test('resolveUpstreamRepositorySlug rejects unsupported active fork remotes consistently', () => {
  assert.throws(
    () => resolveUpstreamRepositorySlug('/tmp/repo', null, { AGENT_PRIORITY_ACTIVE_FORK_REMOTE: 'invalid-remote' }),
    /Unsupported fork remote/i
  );
});

test('parseUpstreamIssuePointerFromBody extracts the mirrored upstream issue contract', () => {
  const pointer = parseUpstreamIssuePointerFromBody(
    '<!-- upstream-issue-url: https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/issues/966 -->\n\nBody'
  );
  assert.deepEqual(pointer, {
    repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
    number: 966,
    url: 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/issues/966'
  });
});

test('determinePrioritySyncExitCode maps no-standing to success and real errors to failure', () => {
  assert.equal(determinePrioritySyncExitCode(null), 0);
  assert.equal(determinePrioritySyncExitCode({ code: 'NO_STANDING_PRIORITY' }), 0);
  assert.equal(determinePrioritySyncExitCode({ code: 'NO_STANDING_PRIORITY' }, { failOnMissing: true }), 1);
  assert.equal(determinePrioritySyncExitCode({ code: 'MULTIPLE_STANDING_PRIORITY' }), 0);
  assert.equal(determinePrioritySyncExitCode({ code: 'MULTIPLE_STANDING_PRIORITY' }, { failOnMultiple: true }), 1);
  assert.equal(determinePrioritySyncExitCode(new Error('boom')), 1);
});

test('shouldRethrowStandingPriorityError skips rethrow after successful auto-select resolution', () => {
  assert.equal(
    shouldRethrowStandingPriorityError(
      { code: 'NO_STANDING_PRIORITY', message: 'no standing issue' },
      { number: 797, repoSlug: 'LabVIEW-Community-CI-CD/compare-vi-cli-action', source: 'auto-select' }
    ),
    false
  );

  assert.equal(
    shouldRethrowStandingPriorityError({ code: 'NO_STANDING_PRIORITY', message: 'no standing issue' }, null),
    true
  );

  assert.equal(
    shouldRethrowStandingPriorityError(new Error('network failure'), { number: 797 }),
    true
  );
});

test('shouldContinueAfterAutoSelectLaneEmpty allows transient empty lane after auto-select', () => {
  assert.equal(
    shouldContinueAfterAutoSelectLaneEmpty({ source: 'auto-select', number: 797 }, []),
    true
  );
  assert.equal(
    shouldContinueAfterAutoSelectLaneEmpty({ source: 'gh', number: 797 }, []),
    false
  );
  assert.equal(
    shouldContinueAfterAutoSelectLaneEmpty({ source: 'auto-select', number: 797 }, [797]),
    false
  );
});

test('parseCliArgs enables strict standing-priority flags and help', () => {
  const parsed = parseCliArgs(['node', 'sync-standing-priority.mjs', '--fail-on-missing']);
  assert.equal(parsed.failOnMissing, true);
  assert.equal(parsed.failOnMultiple, false);
  assert.equal(parsed.autoSelectNext, false);
  assert.equal(parsed.help, false);

  const parsedMulti = parseCliArgs(['node', 'sync-standing-priority.mjs', '--fail-on-multiple']);
  assert.equal(parsedMulti.failOnMultiple, true);
  assert.equal(parsedMulti.failOnMissing, false);

  const parsedAuto = parseCliArgs(['node', 'sync-standing-priority.mjs', '--auto-select-next']);
  assert.equal(parsedAuto.autoSelectNext, true);
  assert.equal(parsedAuto.failOnMissing, false);

  const parsedMaterialize = parseCliArgs(['node', 'sync-standing-priority.mjs', '--materialize-cache']);
  assert.equal(parsedMaterialize.materializeCache, true);

  const help = parseCliArgs(['node', 'sync-standing-priority.mjs', '--help']);
  assert.equal(help.help, true);
});

test('selectAutoStandingPriorityCandidate favors non-epic P0 oldest item', () => {
  const selected = selectAutoStandingPriorityCandidate([
    {
      number: 900,
      title: 'Epic: umbrella',
      labels: ['program'],
      createdAt: '2026-03-06T12:00:00Z'
    },
    {
      number: 901,
      title: '[P1] follow-up lane',
      labels: ['ci'],
      createdAt: '2026-03-06T12:01:00Z'
    },
    {
      number: 902,
      title: '[P0] first lane',
      labels: ['ci'],
      createdAt: '2026-03-06T11:00:00Z'
    },
    {
      number: 903,
      title: '[P0] duplicate lane',
      labels: ['duplicate'],
      createdAt: '2026-03-06T10:00:00Z'
    }
  ]);

  assert.equal(selected?.number, 902);
  assert.equal(selected?.priority, 0);
});

test('selectAutoStandingPriorityCandidate deprioritizes umbrella program issues when actionable children exist', () => {
  const selected = selectAutoStandingPriorityCandidate([
    {
      number: 799,
      title: '[P0] Program umbrella',
      labels: ['program', 'governance'],
      body: '## Child tracks\n1. #805',
      createdAt: '2026-03-06T08:00:00Z'
    },
    {
      number: 805,
      title: '[P0] Defork-safe portability hardening',
      labels: ['program', 'governance'],
      body: '## Parent\n- #799',
      createdAt: '2026-03-06T08:05:00Z'
    }
  ]);

  assert.equal(selected?.number, 805);
});

test('selectAutoStandingPriorityCandidate skips excluded standing issues and deprioritizes cadence alerts', () => {
  const selected = selectAutoStandingPriorityCandidate(
    [
      {
        number: 299,
        title: '[cadence] Package stream freshness alert',
        body: '<!-- cadence-check:package-staleness -->',
        labels: ['ci'],
        createdAt: '2026-03-01T00:00:00Z'
      },
      {
        number: 315,
        title: '[P1] Real development issue',
        body: 'Implement the helper workflow',
        labels: ['ci'],
        createdAt: '2026-03-02T00:00:00Z'
      },
      {
        number: 317,
        title: '[P0] Current standing issue',
        body: 'Already assigned',
        labels: ['fork-standing-priority'],
        createdAt: '2026-03-03T00:00:00Z'
      }
    ],
    {
      excludeIssueNumbers: [317]
    }
  );

  assert.equal(selected?.number, 315);
  assert.equal(selected?.cadence, false);
});

test('selectAutoStandingPriorityCandidate keeps comparevi demo rollout issues in scope', () => {
  const selected = selectAutoStandingPriorityCandidate([
    {
      number: 946,
      title: 'Upstream demo: land released comparevi-history diagnostics in labview-icon-editor-demo',
      body: [
        'Land diagnostics workflows in LabVIEW-Community-CI-CD/labview-icon-editor-demo.',
        'Use released comparevi-history refs only.',
        'Keep the workflow shape fork-safe for downstream forks.',
        'Document how downstream forks should stay aligned to the canonical upstream surface.'
      ].join('\n'),
      labels: [],
      createdAt: '2026-03-01T00:00:00Z'
    },
    {
      number: 951,
      title: 'Epic: harden Copilot remediation by drafting PRs before fix pushes',
      body: 'Remaining in-repo work.',
      labels: ['program'],
      createdAt: '2026-03-02T00:00:00Z'
    }
  ]);

  assert.equal(selected?.number, 946);
});

test('selectAutoStandingPriorityCandidate keeps title-driven comparevi rollout issues in scope', () => {
  const selected = selectAutoStandingPriorityCandidate([
    {
      number: 946,
      title: 'Upstream demo: land upstream-aligned released comparevi-history diagnostics for fork-safe workflow files in labview-icon-editor-demo',
      body: 'See epic for the full rollout plan.',
      labels: [],
      createdAt: '2026-03-01T00:00:00Z'
    },
    {
      number: 951,
      title: 'Epic: harden Copilot remediation by drafting PRs before fix pushes',
      body: 'Remaining in-repo work.',
      labels: ['program'],
      createdAt: '2026-03-02T00:00:00Z'
    }
  ]);

  assert.equal(selected?.number, 946);
});

test('selectAutoStandingPriorityCandidate still excludes true icon-editor demo development issues', () => {
  const selected = selectAutoStandingPriorityCandidate([
    {
      number: 946,
      title: 'Upstream demo: update icon editor assets in labview-icon-editor-demo',
      body: 'Out-of-scope icon editor development work.',
      labels: [],
      createdAt: '2026-03-01T00:00:00Z'
    },
    {
      number: 951,
      title: 'Epic: harden Copilot remediation by drafting PRs before fix pushes',
      body: 'Remaining in-repo work.',
      labels: ['program'],
      createdAt: '2026-03-02T00:00:00Z'
    }
  ]);

  assert.equal(selected?.number, 951);
});

test('selectAutoStandingPriorityCandidate still excludes demo issues with incidental comparevi mentions', () => {
  const selected = selectAutoStandingPriorityCandidate([
    {
      number: 946,
      title: 'Upstream demo: update icon editor assets in labview-icon-editor-demo',
      body: 'Icon editor asset work that references comparevi-history for screenshot context only.',
      labels: [],
      createdAt: '2026-03-01T00:00:00Z'
    },
    {
      number: 951,
      title: 'Epic: harden Copilot remediation by drafting PRs before fix pushes',
      body: 'Remaining in-repo work.',
      labels: ['program'],
      createdAt: '2026-03-02T00:00:00Z'
    }
  ]);

  assert.equal(selected?.number, 951);
});

test('selectAutoStandingPriorityCandidate still excludes demo issues that only mention released comparevi refs', () => {
  const selected = selectAutoStandingPriorityCandidate([
    {
      number: 946,
      title: 'Upstream demo: update icon editor assets in labview-icon-editor-demo',
      body: 'Use released comparevi-history refs only while refreshing icon editor screenshots.',
      labels: [],
      createdAt: '2026-03-01T00:00:00Z'
    },
    {
      number: 951,
      title: 'Epic: harden Copilot remediation by drafting PRs before fix pushes',
      body: 'Remaining in-repo work.',
      labels: ['program'],
      createdAt: '2026-03-02T00:00:00Z'
    }
  ]);

  assert.equal(selected?.number, 951);
});

test('selectAutoStandingPriorityCandidate still excludes non-rollout demo maintenance that mentions workflow plumbing', () => {
  const selected = selectAutoStandingPriorityCandidate([
    {
      number: 946,
      title: 'Upstream demo: refresh labview-icon-editor-demo README',
      body: [
        'Document released comparevi-history refs.',
        'Mention workflow files and downstream forks for operator context.',
        'This is still demo maintenance, not a rollout lane.'
      ].join('\n'),
      labels: [],
      createdAt: '2026-03-01T00:00:00Z'
    },
    {
      number: 951,
      title: 'Epic: harden Copilot remediation by drafting PRs before fix pushes',
      body: 'Remaining in-repo work.',
      labels: ['program'],
      createdAt: '2026-03-02T00:00:00Z'
    }
  ]);

  assert.equal(selected?.number, 951);
});

test('selectAutoStandingPriorityCandidate still excludes docs maintenance with rollout-shaped wording', () => {
  const selected = selectAutoStandingPriorityCandidate([
    {
      number: 946,
      title: 'Upstream demo: refresh labview-icon-editor-demo docs',
      body: [
        'Update docs for released comparevi-history workflow files.',
        'Mention downstream forks for operator context.',
        'This is docs maintenance, not a rollout lane.'
      ].join('\n'),
      labels: [],
      createdAt: '2026-03-01T00:00:00Z'
    },
    {
      number: 951,
      title: 'Epic: harden Copilot remediation by drafting PRs before fix pushes',
      body: 'Remaining in-repo work.',
      labels: ['program'],
      createdAt: '2026-03-02T00:00:00Z'
    }
  ]);

  assert.equal(selected?.number, 951);
});

test('selectAutoStandingPriorityCandidate skips explicitly blocked rollout trackers', () => {
  const selected = selectAutoStandingPriorityCandidate([
    {
      number: 946,
      title: 'Upstream demo: land released comparevi-history diagnostics in labview-icon-editor-demo',
      body: [
        'Land diagnostics workflows in the upstream demo repo.',
        'Blocked by comparevi-history#23.'
      ].join('\n'),
      labels: [],
      createdAt: '2026-03-01T00:00:00Z'
    },
    {
      number: 951,
      title: '[P1] actionable follow-up',
      body: 'Remaining in-repo work.',
      labels: [],
      createdAt: '2026-03-02T00:00:00Z'
    }
  ]);

  assert.equal(selected?.number, 951);
});

test('selectAutoStandingPriorityCandidate keeps rollout trackers eligible when blocker wording is historical or negated', () => {
  const selected = selectAutoStandingPriorityCandidate([
    {
      number: 946,
      title: 'Upstream demo: land released comparevi-history diagnostics in labview-icon-editor-demo',
      body: [
        'Land diagnostics workflows in the upstream demo repo.',
        'No longer blocked by comparevi-history#23 after the explicit-mode renderer landed.'
      ].join('\n'),
      labels: [],
      createdAt: '2026-03-01T00:00:00Z'
    },
    {
      number: 951,
      title: 'Epic: harden Copilot remediation by drafting PRs before fix pushes',
      body: 'Remaining in-repo work.',
      labels: ['program'],
      createdAt: '2026-03-02T00:00:00Z'
    }
  ]);

  assert.equal(selected?.number, 946);
});

test('selectAutoStandingPriorityCandidate skips explicit external-only tracking rollout issues after shared blockers close', () => {
  const selected = selectAutoStandingPriorityCandidate([
    {
      number: 946,
      title: 'Upstream demo: land released comparevi-history diagnostics in labview-icon-editor-demo',
      body: [
        'The remaining post-merge public-surface work is now tracked outside this repository.',
        'This issue remains open only as local blocked tracking under epic #930.',
        'Under the current standing selector, this issue is blocked tracking, not an active local standing lane.',
        'Do not open a new in-repo coding lane here unless a real compare-vi-cli-action defect is discovered.'
      ].join('\n'),
      labels: [],
      createdAt: '2026-03-01T00:00:00Z'
    },
    {
      number: 951,
      title: 'Epic: harden Copilot remediation by drafting PRs before fix pushes',
      body: 'Remaining in-repo work.',
      labels: ['program'],
      createdAt: '2026-03-02T00:00:00Z'
    }
  ]);

  assert.equal(selected?.number, 951);
});

test('selectAutoStandingPriorityCandidate skips explicit external-only tracking when the demotion is expressed across two sentences', () => {
  const selected = selectAutoStandingPriorityCandidate([
    {
      number: 946,
      title: 'Upstream demo: land released comparevi-history diagnostics in labview-icon-editor-demo',
      body: [
        'The remaining post-merge public-surface work is now tracked outside this repository.',
        'This issue is not an active local standing lane.',
        'Do not open a new in-repo coding lane here unless a real compare-vi-cli-action defect is discovered.'
      ].join('\n'),
      labels: [],
      createdAt: '2026-03-01T00:00:00Z'
    },
    {
      number: 951,
      title: 'Epic: harden Copilot remediation by drafting PRs before fix pushes',
      body: 'Remaining in-repo work.',
      labels: ['program'],
      createdAt: '2026-03-02T00:00:00Z'
    }
  ]);

  assert.equal(selected?.number, 951);
});

test('selectAutoStandingPriorityCandidate keeps rollout trackers eligible when external-only tracking wording is historical', () => {
  const selected = selectAutoStandingPriorityCandidate([
    {
      number: 946,
      title: 'Upstream demo: land released comparevi-history diagnostics in labview-icon-editor-demo',
      body: [
        'Historical note: this issue was blocked tracking, not an active local standing lane during the comparevi-history#23 phase.',
        'Use released comparevi-history refs only.',
        'Keep the workflow shape fork-safe for downstream forks.'
      ].join('\n'),
      labels: [],
      createdAt: '2026-03-01T00:00:00Z'
    },
    {
      number: 951,
      title: 'Epic: harden Copilot remediation by drafting PRs before fix pushes',
      body: 'Remaining in-repo work.',
      labels: ['program'],
      createdAt: '2026-03-02T00:00:00Z'
    }
  ]);

  assert.equal(selected?.number, 946);
});

test('selectAutoStandingPriorityCandidate keeps rollout trackers eligible when multiline historical notes precede external-only wording', () => {
  const selected = selectAutoStandingPriorityCandidate([
    {
      number: 946,
      title: 'Upstream demo: land released comparevi-history diagnostics in labview-icon-editor-demo',
      body: [
        'Historical note:',
        'This issue remains open only as local blocked tracking under epic #930.',
        'Under the current standing selector, this issue is blocked tracking, not an active local standing lane.'
      ].join('\n'),
      labels: [],
      createdAt: '2026-03-01T00:00:00Z'
    },
    {
      number: 951,
      title: 'Epic: harden Copilot remediation by drafting PRs before fix pushes',
      body: 'Remaining in-repo work.',
      labels: ['program'],
      createdAt: '2026-03-02T00:00:00Z'
    }
  ]);

  assert.equal(selected?.number, 946);
});

test('selectAutoStandingPriorityCandidate keeps rollout trackers eligible when blocked-tracking wording is explicitly negated', () => {
  const selected = selectAutoStandingPriorityCandidate([
    {
      number: 946,
      title: '[P0] Upstream demo: land released comparevi-history diagnostics in labview-icon-editor-demo',
      body: [
        'Current status: the rollout lane is active again.',
        'This issue no longer remains open only as local blocked tracking under epic #930.',
        'Keep the workflow shape fork-safe for downstream forks.'
      ].join('\n'),
      labels: [],
      createdAt: '2026-03-01T00:00:00Z'
    },
    {
      number: 951,
      title: 'Epic: harden Copilot remediation by drafting PRs before fix pushes',
      body: 'Remaining in-repo work.',
      labels: ['program'],
      createdAt: '2026-03-02T00:00:00Z'
    }
  ]);

  assert.equal(selected?.number, 946);
});

test('selectAutoStandingPriorityCandidate keeps rollout trackers eligible when comparevi-history was only a historical downstream blocker', () => {
  const selected = selectAutoStandingPriorityCandidate([
    {
      number: 946,
      title: 'Upstream demo: land released comparevi-history diagnostics in labview-icon-editor-demo',
      body: [
        'Land diagnostics workflows in the upstream demo repo.',
        'comparevi-history#23 was the primary downstream blocker before the renderer landed.'
      ].join('\n'),
      labels: [],
      createdAt: '2026-03-01T00:00:00Z'
    },
    {
      number: 951,
      title: 'Epic: harden Copilot remediation by drafting PRs before fix pushes',
      body: 'Remaining in-repo work.',
      labels: ['program'],
      createdAt: '2026-03-02T00:00:00Z'
    }
  ]);

  assert.equal(selected?.number, 946);
});

test('selectAutoStandingPriorityCandidate honors hydrated comment bodies even when numeric comment counts are also present', () => {
  const selected = selectAutoStandingPriorityCandidate([
    {
      number: 946,
      title: 'Upstream demo: land released comparevi-history diagnostics in labview-icon-editor-demo',
      body: 'Track comparevi-history#23 as the blocker for the final public explicit-mode reviewer surface.',
      comments: 2,
      commentBodies: [
        'Standing-priority moved away because the remaining gap is externally blocked on comparevi-history#23 and this is no longer the top actionable coding lane.'
      ],
      labels: [],
      createdAt: '2026-03-01T00:00:00Z'
    },
    {
      number: 951,
      title: '[P1] actionable follow-up',
      body: 'Remaining in-repo work.',
      labels: [],
      createdAt: '2026-03-02T00:00:00Z'
    }
  ]);

  assert.equal(selected?.number, 951);
});

test('selectAutoStandingPriorityCandidate keeps rollout trackers eligible when blocker text is not the external comparevi-history gate', () => {
  const selected = selectAutoStandingPriorityCandidate([
    {
      number: 946,
      title: 'Upstream demo: land released comparevi-history diagnostics in labview-icon-editor-demo',
      body: 'Track comparevi-history#23 as the blocker for the final public explicit-mode reviewer surface.',
      comments: ['Blocked by fixture drift cleanup before landing.'],
      labels: [],
      createdAt: '2026-03-01T00:00:00Z'
    },
    {
      number: 951,
      title: 'Epic: harden Copilot remediation by drafting PRs before fix pushes',
      body: 'Remaining in-repo work.',
      labels: ['program'],
      createdAt: '2026-03-02T00:00:00Z'
    }
  ]);

  assert.equal(selected?.number, 946);
});

test('selectAutoStandingPriorityCandidate keeps rollout trackers eligible when generic blocker text and comparevi-history tracker notes are separate body clauses', () => {
  const selected = selectAutoStandingPriorityCandidate([
    {
      number: 946,
      title: 'Upstream demo: land released comparevi-history diagnostics in labview-icon-editor-demo',
      body: [
        'Blocked by fixture drift cleanup before landing.',
        'Track comparevi-history#23 as the remaining explicit-mode renderer dependency.'
      ].join('\n'),
      labels: [],
      createdAt: '2026-03-01T00:00:00Z'
    },
    {
      number: 951,
      title: 'Epic: harden Copilot remediation by drafting PRs before fix pushes',
      body: 'Remaining in-repo work.',
      labels: ['program'],
      createdAt: '2026-03-02T00:00:00Z'
    }
  ]);

  assert.equal(selected?.number, 946);
});

test('selectAutoStandingPriorityCandidate keeps non-demo labview-icon-editor references eligible', () => {
  const selected = selectAutoStandingPriorityCandidate([
    {
      number: 960,
      title: '[P1] align compare-vi docs with labview-icon-editor release notes',
      body: 'In-scope compare-vi documentation work.',
      labels: ['ci'],
      createdAt: '2026-03-01T00:00:00Z'
    }
  ]);

  assert.equal(selected?.number, 960);
});

test('selectAutoStandingPriorityCandidate skips passive platform-stale trackers when actionable coding lanes exist', () => {
  const selected = selectAutoStandingPriorityCandidate([
    {
      number: 1426,
      title: 'Track stale Dependabot alerts after npm remediation on develop',
      body: [
        'tools/priority/security-intake.mjs now classifies the current state as platform-stale.',
        'This follow-up tracks the remaining GitHub dependency-graph / Dependabot refresh lag until the platform state catches up.',
        'Dependabot alerts auto-close or are otherwise reconciled by GitHub.'
      ].join('\n'),
      labels: [],
      createdAt: '2026-03-01T00:00:00Z'
    },
    {
      number: 1510,
      title: '[P1] Build a cross-repo standing-lane marketplace for autonomous worker allocation',
      body: 'Actionable in-repo coding work remains.',
      labels: ['ci'],
      createdAt: '2026-03-02T00:00:00Z'
    }
  ]);

  assert.equal(selected?.number, 1510);
});

test('selectAutoStandingPriorityCandidateForRepo skips excluded issue numbers before comment hydration', async () => {
  const selected = await selectAutoStandingPriorityCandidateForRepo('/tmp/repo', 'owner/repo', [
    {
      number: 946,
      title: 'Upstream demo: land released comparevi-history diagnostics in labview-icon-editor-demo',
      body: 'Track comparevi-history#23 as the blocker for the final public explicit-mode reviewer surface.',
      labels: []
    },
    {
      number: 951,
      title: '[P1] actionable follow-up',
      body: 'Remaining in-repo work.',
      labels: []
    }
  ], {
    excludeIssueNumbers: [946],
    fetchIssueDetailsFn: async (issueNumber) => {
      throw new Error(`should not hydrate excluded issue #${issueNumber}`);
    },
    warn: () => {}
  });

  assert.equal(selected?.number, 951);
});

test('selectAutoStandingPriorityCandidateForRepo hydrates comment-only blocked demotions even when rollout scope is otherwise narrow', async () => {
  const selected = await selectAutoStandingPriorityCandidateForRepo('/tmp/repo', 'owner/repo', [
    {
      number: 946,
      title: '[P0] Wire comparevi-history renderer integration',
      body: 'Track comparevi-history#23 while the renderer dependency is still external.',
      labels: [],
      createdAt: '2026-03-01T00:00:00Z'
    },
    {
      number: 951,
      title: '[P1] actionable follow-up',
      body: 'Remaining in-repo work.',
      labels: [],
      createdAt: '2026-03-02T00:00:00Z'
    }
  ], {
    fetchIssueDetailsFn: async (issueNumber) =>
      issueNumber === 946
        ? {
            number: 946,
            title: '[P0] Wire comparevi-history renderer integration',
            body: 'Track comparevi-history#23 while the renderer dependency is still external.',
            commentBodies: [
              'Standing-priority moved away because the remaining gap is externally blocked on comparevi-history#23 and this is no longer the top actionable coding lane.'
            ]
          }
        : {
            number: 951,
            title: '[P1] actionable follow-up',
            body: 'Remaining in-repo work.',
            commentBodies: []
          },
    externalIssueStateFetcher: buildExternalIssueStateFetcher(),
    warn: () => {}
  });

  assert.equal(selected?.number, 951);
});

test('selectAutoStandingPriorityCandidateForRepo clears blocked rollout demotions when the external blocker is already closed', async () => {
  const selected = await selectAutoStandingPriorityCandidateForRepo('/tmp/repo', 'owner/repo', [
    {
      number: 946,
      title: '[P0] Wire comparevi-history renderer integration',
      body: 'Track comparevi-history#23 while the renderer dependency is still external.',
      labels: [],
      createdAt: '2026-03-01T00:00:00Z'
    },
    {
      number: 951,
      title: '[P1] actionable follow-up',
      body: 'Remaining in-repo work.',
      labels: [],
      createdAt: '2026-03-02T00:00:00Z'
    }
  ], {
    fetchIssueDetailsFn: async (issueNumber) =>
      issueNumber === 946
        ? {
            number: 946,
            title: '[P0] Wire comparevi-history renderer integration',
            body: 'Track comparevi-history#23 while the renderer dependency is still external.',
            commentBodies: [
              'Standing-priority moved away because the remaining gap is externally blocked on comparevi-history#23 and this is no longer the top actionable coding lane.'
            ]
          }
        : {
            number: 951,
            title: '[P1] actionable follow-up',
            body: 'Remaining in-repo work.',
            commentBodies: []
          },
    externalIssueStateFetcher: buildExternalIssueStateFetcher({ 23: 'closed' }),
    warn: () => {}
  });

  assert.equal(selected?.number, 946);
});

test('selectAutoStandingPriorityCandidateForRepo honors hydrated comment-only explicit external-tracking demotions', async () => {
  const selected = await selectAutoStandingPriorityCandidateForRepo('/tmp/repo', 'owner/repo', [
    {
      number: 946,
      title: 'Upstream demo: land released comparevi-history diagnostics in labview-icon-editor-demo',
      body: [
        'The canonical upstream demo rollout already landed in LabVIEW-Community-CI-CD/labview-icon-editor-demo.',
        'Keep the workflow shape fork-safe for downstream forks.'
      ].join('\n'),
      labels: [],
      createdAt: '2026-03-01T00:00:00Z'
    },
    {
      number: 951,
      title: '[P1] actionable follow-up',
      body: 'Remaining in-repo work.',
      labels: [],
      createdAt: '2026-03-02T00:00:00Z'
    }
  ], {
    fetchIssueDetailsFn: async (issueNumber) =>
      issueNumber === 946
        ? {
            number: 946,
            title: 'Upstream demo: land released comparevi-history diagnostics in labview-icon-editor-demo',
            body: [
              'The canonical upstream demo rollout already landed in LabVIEW-Community-CI-CD/labview-icon-editor-demo.',
              'Keep the workflow shape fork-safe for downstream forks.'
            ].join('\n'),
            commentBodies: [
              'This issue remains open only as local blocked tracking under epic #930.',
              'Under the current standing selector, this issue is blocked tracking, not an active local standing lane.'
            ]
          }
        : {
            number: 951,
            title: '[P1] actionable follow-up',
            body: 'Remaining in-repo work.',
            commentBodies: []
          },
    warn: () => {}
  });

  assert.equal(selected?.number, 951);
});

test('selectAutoStandingPriorityCandidateForRepo keeps rollout issues eligible when current body reactivation overrides stale comment demotions', async () => {
  const selected = await selectAutoStandingPriorityCandidateForRepo('/tmp/repo', 'owner/repo', [
    {
      number: 946,
      title: 'Upstream demo: land released comparevi-history diagnostics in labview-icon-editor-demo',
      body: [
        'Current status: the rollout lane is active again.',
        'This issue no longer remains open only as local blocked tracking under epic #930.',
        'Keep the workflow shape fork-safe for downstream forks.'
      ].join('\n'),
      labels: [],
      createdAt: '2026-03-01T00:00:00Z'
    },
    {
      number: 951,
      title: '[P1] actionable follow-up',
      body: 'Remaining in-repo work.',
      labels: [],
      createdAt: '2026-03-02T00:00:00Z'
    }
  ], {
    fetchIssueDetailsFn: async (issueNumber) =>
      issueNumber === 946
        ? {
            number: 946,
            title: '[P0] Upstream demo: land released comparevi-history diagnostics in labview-icon-editor-demo',
            body: [
              'Current status: the rollout lane is active again.',
              'This issue no longer remains open only as local blocked tracking under epic #930.',
              'Keep the workflow shape fork-safe for downstream forks.'
            ].join('\n'),
            commentBodies: [
              'This issue remains open only as local blocked tracking under epic #930.',
              'Under the current standing selector, this issue is blocked tracking, not an active local standing lane.'
            ]
          }
        : {
            number: 951,
            title: '[P1] actionable follow-up',
            body: 'Remaining in-repo work.',
            commentBodies: []
          },
    warn: () => {}
  });

  assert.equal(selected?.number, 946);
});

test('selectAutoStandingPriorityCandidate idles instead of promoting an umbrella fallback when only blocked concrete children remain', () => {
  const entries = [
    {
      number: 930,
      title: 'Epic: route released comparevi workflows through downstream rollout gates',
      body: ['## Child tracks', '- #946', '- #947'].join('\n'),
      labels: ['program'],
      createdAt: '2026-03-01T00:00:00Z'
    },
    {
      number: 946,
      title: '[P1] upstream rollout child',
      body: ['Parent epic: #930', 'The remaining work is externally blocked on comparevi-history#23.'].join('\n'),
      labels: [],
      createdAt: '2026-03-02T00:00:00Z'
    },
    {
      number: 947,
      title: '[P1] downstream rollout child',
      body: ['Parent epic: #930', 'The remaining work is externally blocked on comparevi-history#23.'].join('\n'),
      labels: [],
      createdAt: '2026-03-03T00:00:00Z'
    }
  ];

  assert.equal(hasOnlyBlockedConcreteIssuesBehindFallbackParent(entries), true);
  assert.equal(selectAutoStandingPriorityCandidate(entries), null);
});

test('selectAutoStandingPriorityCandidate still falls back to the umbrella epic when it is the only remaining in-scope issue', () => {
  const entries = [
    {
      number: 930,
      title: 'Epic: route released comparevi workflows through downstream rollout gates',
      body: 'Umbrella tracking for comparevi rollout.',
      labels: ['program'],
      createdAt: '2026-03-01T00:00:00Z'
    }
  ];

  assert.equal(hasOnlyBlockedConcreteIssuesBehindFallbackParent(entries), false);
  assert.equal(selectAutoStandingPriorityCandidate(entries)?.number, 930);
});

test('selectAutoStandingPriorityCandidate keeps an unrelated umbrella issue eligible when blocked concrete children are not linked to it', () => {
  const entries = [
    {
      number: 930,
      title: 'Epic: unrelated rollout coordination',
      body: 'Umbrella tracking for a different stream.',
      labels: ['program'],
      createdAt: '2026-03-01T00:00:00Z'
    },
    {
      number: 946,
      title: '[P1] upstream rollout child',
      body: 'The remaining work is externally blocked on comparevi-history#23.',
      labels: [],
      createdAt: '2026-03-02T00:00:00Z'
    }
  ];

  assert.equal(hasOnlyBlockedConcreteIssuesBehindFallbackParent(entries), false);
  assert.equal(selectAutoStandingPriorityCandidate(entries)?.number, 930);
});

test('selectAutoStandingPriorityCandidate keeps an earlier unrelated umbrella eligible when a later umbrella owns the blocked children', () => {
  const entries = [
    {
      number: 930,
      title: 'Epic: unrelated rollout coordination',
      body: 'Umbrella tracking for a different stream.',
      labels: ['program'],
      createdAt: '2026-03-01T00:00:00Z'
    },
    {
      number: 931,
      title: 'Epic: linked rollout coordination',
      body: ['## Child tracks', '- #946'].join('\n'),
      labels: ['program'],
      createdAt: '2026-03-02T00:00:00Z'
    },
    {
      number: 946,
      title: '[P1] upstream rollout child',
      body: ['Parent epic: #931', 'The remaining work is externally blocked on comparevi-history#23.'].join('\n'),
      labels: [],
      createdAt: '2026-03-03T00:00:00Z'
    }
  ];

  assert.equal(hasOnlyBlockedConcreteIssuesBehindFallbackParent(entries), false);
  assert.equal(selectAutoStandingPriorityCandidate(entries)?.number, 930);
});

test('selectAutoStandingPriorityCandidate still idles when linked blocked concrete children also carry the program label', () => {
  const entries = [
    {
      number: 930,
      title: 'Epic: route released comparevi workflows through downstream rollout gates',
      body: ['## Child tracks', '- #946'].join('\n'),
      labels: ['program'],
      createdAt: '2026-03-01T00:00:00Z'
    },
    {
      number: 946,
      title: '[P1] upstream rollout child',
      body: ['Parent epic: #930', 'The remaining work is externally blocked on comparevi-history#23.'].join('\n'),
      labels: ['program'],
      createdAt: '2026-03-02T00:00:00Z'
    }
  ];

  assert.equal(hasOnlyBlockedConcreteIssuesBehindFallbackParent(entries), true);
  assert.equal(selectAutoStandingPriorityCandidate(entries), null);
});

test('shouldPersistCacheUpdate skips cache materialization by default on fresh clones', () => {
  const nextCache = {
    number: 805,
    state: 'OPEN',
    labels: ['standing-priority']
  };
  assert.equal(
    shouldPersistCacheUpdate({}, nextCache, { hasCacheFile: false, materializeCache: false }),
    false
  );
  assert.equal(
    shouldPersistCacheUpdate({}, nextCache, { hasCacheFile: false, materializeCache: true }),
    true
  );
});

test('autoSelectStandingPriorityIssue selects and labels next issue via injected transports', async () => {
  const calls = [];
  const result = await autoSelectStandingPriorityIssue('/tmp/repo', 'owner/repo', {
    targetSlug: 'owner/repo',
    runGhList: () => ({
      status: 0,
      stdout: JSON.stringify([
        { number: 910, title: 'Epic: umbrella', labels: [{ name: 'program' }], createdAt: '2026-03-06T12:00:00Z' },
        { number: 911, title: '[P0] lane', labels: [{ name: 'ci' }], createdAt: '2026-03-06T10:00:00Z' }
      ])
    }),
    runGhAddLabel: ({ issueNumber }) => {
      calls.push(issueNumber);
      return { status: 0, stdout: '' };
    },
    runRestList: async () => ({ status: 'error', error: 'not-used' }),
    runRestAddLabel: async () => ({ status: 'error', error: 'not-used' }),
    warn: () => {}
  });

  assert.equal(result.status, 'selected');
  assert.equal(result.issue?.number, 911);
  assert.equal(result.openIssueCount, 2);
  assert.equal(result.candidateSource, 'gh');
  assert.equal(result.labelAssignmentSource, 'gh');
  assert.deepEqual(calls, [911]);
});

test('autoSelectStandingPriorityIssue reports empty when only out-of-scope demo issues remain', async () => {
  const result = await autoSelectStandingPriorityIssue('/tmp/repo', 'owner/repo', {
    targetSlug: 'owner/repo',
    runGhList: () => ({
      status: 0,
      stdout: JSON.stringify([
        {
          number: 946,
          title: 'Upstream demo: update icon editor assets in labview-icon-editor-demo',
          body: 'Out-of-scope icon editor development work.',
          labels: [],
          createdAt: '2026-03-01T00:00:00Z'
        }
      ])
    }),
    runGhAddLabel: () => {
      throw new Error('should not label an out-of-scope issue');
    },
    runRestList: async () => ({ status: 'error', error: 'not-used' }),
    runRestAddLabel: async () => ({ status: 'error', error: 'not-used' }),
    warn: () => {}
  });

  assert.equal(result.status, 'empty');
  assert.equal(result.openIssueCount, 1);
});

test('buildNoStandingPriorityReport emits deterministic schema payload', () => {
  const report = buildNoStandingPriorityReport({
    message: 'No open issue found',
    labels: ['fork-standing-priority', 'standing-priority'],
    repository: 'owner/repo',
    reason: 'label-missing',
    openIssueCount: 3,
    failOnMissing: true,
    generatedAt: '2026-03-05T22:30:00.000Z'
  });
  assert.deepEqual(report, {
    schema: 'standing-priority/no-standing@v1',
    generatedAt: '2026-03-05T22:30:00.000Z',
    repository: 'owner/repo',
    labels: ['fork-standing-priority', 'standing-priority'],
    message: 'No open issue found',
    reason: 'label-missing',
    openIssueCount: 3,
    failOnMissing: true
  });
});

test('buildAutoPromotedStandingPriorityReport emits deterministic schema payload', () => {
  const report = buildAutoPromotedStandingPriorityReport({
    repository: 'owner/repo',
    checkedLabels: ['fork-standing-priority', 'standing-priority'],
    issue: {
      number: 911,
      title: '[P0] lane',
      url: 'https://github.com/owner/repo/issues/911',
      priority: 0
    },
    candidateSource: 'gh',
    labelAssignmentSource: 'rest',
    openIssueCount: 4,
    generatedAt: '2026-03-21T02:30:00.000Z'
  });

  assert.deepEqual(report, {
    schema: 'standing-priority/auto-promoted@v1',
    generatedAt: '2026-03-21T02:30:00.000Z',
    repository: 'owner/repo',
    checkedLabels: ['fork-standing-priority', 'standing-priority'],
    issue: {
      number: 911,
      title: '[P0] lane',
      url: 'https://github.com/owner/repo/issues/911',
      priority: 0
    },
    candidateSource: 'gh',
    labelAssignmentSource: 'rest',
    openIssueCount: 4,
    message: 'Auto-promoted #911 into explicit `standing-priority` state.'
  });
});

test('classifyNoStandingPriorityCondition detects queue-empty repositories', async () => {
  const result = await classifyNoStandingPriorityCondition('/tmp/repo', 'owner/repo', ['standing-priority'], {
    targetSlug: 'owner/repo',
    runGhList: () => ({
      status: 0,
      stdout: '[]'
    }),
    runRestList: async () => ({ status: 'error', error: 'not-used' }),
    warn: () => {}
  });

  assert.deepEqual(result, {
    status: 'classified',
    reason: 'queue-empty',
    repository: 'owner/repo',
    openIssueCount: 0,
    message: 'No open issues remain in owner/repo; the standing-priority queue is empty.'
  });
});

test('classifyNoStandingPriorityCondition distinguishes label-missing from queue-empty', async () => {
  const result = await classifyNoStandingPriorityCondition('/tmp/repo', 'owner/repo', ['standing-priority'], {
    targetSlug: 'owner/repo',
    runGhList: () => ({
      status: 0,
      stdout: JSON.stringify([{ number: 911, title: 'follow-up', labels: [{ name: 'bug' }] }])
    }),
    runRestList: async () => ({ status: 'error', error: 'not-used' }),
    warn: () => {}
  });

  assert.equal(result.status, 'classified');
  assert.equal(result.reason, 'label-missing');
  assert.equal(result.repository, 'owner/repo');
  assert.equal(result.openIssueCount, 1);
  assert.match(result.message, /none carry the checked standing-priority labels/i);
});

test('classifyNoStandingPriorityCondition treats out-of-scope-only open issues as queue-empty', async () => {
  const result = await classifyNoStandingPriorityCondition('/tmp/repo', 'owner/repo', ['standing-priority'], {
    targetSlug: 'owner/repo',
    runGhList: () => ({
      status: 0,
      stdout: JSON.stringify([
        {
          number: 930,
          title: 'Epic: refresh icon editor assets in labview-icon-editor-demo',
          labels: ['program']
        },
        {
          number: 946,
          title: 'Upstream demo: update icon editor assets in labview-icon-editor-demo',
          labels: []
        }
      ])
    }),
    runRestList: async () => ({ status: 'error', error: 'not-used' }),
    warn: () => {}
  });

  assert.deepEqual(result, {
    status: 'classified',
    reason: 'queue-empty',
    repository: 'owner/repo',
    openIssueCount: 2,
    message: 'No eligible in-scope open issues remain in owner/repo; the standing-priority queue is empty.'
  });
});

test('classifyNoStandingPriorityCondition keeps comparevi demo rollout queues in scope', async () => {
  const result = await classifyNoStandingPriorityCondition('/tmp/repo', 'owner/repo', ['standing-priority'], {
    targetSlug: 'owner/repo',
    runGhList: () => ({
      status: 0,
      stdout: JSON.stringify([
        {
          number: 930,
          title: 'Epic: route released compare-vi-cli-action through comparevi-history into labview-icon-editor-demo',
          body: [
            'Use released compare-vi-cli-action artifacts through comparevi-history.',
            'Add fork-ready diagnostics workflows.',
            'Keep downstream forks aligned to the canonical upstream surface.',
            'Document the upstream and downstream alignment contract.'
          ].join('\n'),
          labels: ['program']
        },
        {
          number: 946,
          title: 'Upstream demo: land released comparevi-history diagnostics in labview-icon-editor-demo',
          body: [
            'Land diagnostics workflows in the upstream demo repo.',
            'Use released comparevi-history refs only.',
            'Resolve the workflow shape dynamically for downstream forks.',
            'Document how upstream canon should stay aligned into downstream forks.'
          ].join('\n'),
          labels: []
        }
      ])
    }),
    fetchIssueDetailsFn: async () => ({
      title: 'Downstream fork: validate upstream-aligned comparevi-history diagnostics in svelderrainruiz/labview-icon-editor-demo',
      body: [
        'Validate that downstream forks stay aligned with the upstream comparevi-history diagnostics shape.',
        'Route the reviewer-facing diagnostics workflow files through the canonical upstream repo/ref contract.',
        'Keep the downstream fork ready to mirror the released compare-vi-cli-action rollout.'
      ].join('\n'),
      commentCount: 0,
      commentBodies: []
    }),
    runRestList: async () => ({ status: 'error', error: 'not-used' }),
    warn: () => {}
  });

  assert.equal(result.status, 'classified');
  assert.equal(result.reason, 'label-missing');
  assert.equal(result.repository, 'owner/repo');
  assert.equal(result.openIssueCount, 2);
  assert.match(result.message, /none carry the checked standing-priority labels/i);
});

test('classifyNoStandingPriorityCondition keeps title-driven rollout queues in scope', async () => {
  const result = await classifyNoStandingPriorityCondition('/tmp/repo', 'owner/repo', ['standing-priority'], {
    targetSlug: 'owner/repo',
    runGhList: () => ({
      status: 0,
      stdout: JSON.stringify([
        {
          number: 946,
          title: 'Upstream demo: land upstream-aligned released comparevi-history diagnostics for fork-safe workflow files in labview-icon-editor-demo',
          body: 'See epic for the full rollout plan.',
          labels: []
        }
      ])
    }),
    fetchIssueDetailsFn: async () => ({
      title: 'Upstream demo: land released comparevi-history diagnostics in labview-icon-editor-demo',
      body: [
        'Land the released comparevi-history diagnostics workflow files in the upstream demo repo.',
        'Keep PR head repo/ref routing fork-safe for downstream mirrors.',
        'Track comparevi-history#23 as the remaining explicit-mode renderer dependency.'
      ].join('\n'),
      commentCount: 0,
      commentBodies: []
    }),
    runRestList: async () => ({ status: 'error', error: 'not-used' }),
    warn: () => {}
  });

  assert.equal(result.status, 'classified');
  assert.equal(result.reason, 'label-missing');
  assert.equal(result.repository, 'owner/repo');
  assert.equal(result.openIssueCount, 1);
  assert.match(result.message, /none carry the checked standing-priority labels/i);
});

test('classifyNoStandingPriorityCondition still treats generic comparevi references in demo queues as out of scope', async () => {
  const result = await classifyNoStandingPriorityCondition('/tmp/repo', 'owner/repo', ['standing-priority'], {
    targetSlug: 'owner/repo',
    runGhList: () => ({
      status: 0,
      stdout: JSON.stringify([
        {
          number: 946,
          title: 'Upstream demo: update icon editor assets in labview-icon-editor-demo',
          body: 'Refresh icon editor assets while noting compare-vi-cli-action in release notes.',
          labels: []
        }
      ])
    }),
    runRestList: async () => ({ status: 'error', error: 'not-used' }),
    warn: () => {}
  });

  assert.deepEqual(result, {
    status: 'classified',
    reason: 'queue-empty',
    repository: 'owner/repo',
    openIssueCount: 1,
    message: 'No eligible in-scope open issues remain in owner/repo; the standing-priority queue is empty.'
  });
});

test('classifyNoStandingPriorityCondition still treats released-ref-only demo queues as out of scope', async () => {
  const result = await classifyNoStandingPriorityCondition('/tmp/repo', 'owner/repo', ['standing-priority'], {
    targetSlug: 'owner/repo',
    runGhList: () => ({
      status: 0,
      stdout: JSON.stringify([
        {
          number: 946,
          title: 'Upstream demo: update icon editor assets in labview-icon-editor-demo',
          body: 'Use released comparevi-history refs only while refreshing icon editor screenshots.',
          labels: []
        }
      ])
    }),
    runRestList: async () => ({ status: 'error', error: 'not-used' }),
    warn: () => {}
  });

  assert.deepEqual(result, {
    status: 'classified',
    reason: 'queue-empty',
    repository: 'owner/repo',
    openIssueCount: 1,
    message: 'No eligible in-scope open issues remain in owner/repo; the standing-priority queue is empty.'
  });
});

test('classifyNoStandingPriorityCondition still excludes non-rollout demo maintenance with workflow wording', async () => {
  const result = await classifyNoStandingPriorityCondition('/tmp/repo', 'owner/repo', ['standing-priority'], {
    targetSlug: 'owner/repo',
    runGhList: () => ({
      status: 0,
      stdout: JSON.stringify([
        {
          number: 946,
          title: 'Upstream demo: refresh labview-icon-editor-demo README',
          body: [
            'Document released comparevi-history refs.',
            'Mention workflow files and downstream forks for operator context.',
            'This is still demo maintenance, not a rollout lane.'
          ].join('\n'),
          labels: []
        }
      ])
    }),
    runRestList: async () => ({ status: 'error', error: 'not-used' }),
    warn: () => {}
  });

  assert.deepEqual(result, {
    status: 'classified',
    reason: 'queue-empty',
    repository: 'owner/repo',
    openIssueCount: 1,
    message: 'No eligible in-scope open issues remain in owner/repo; the standing-priority queue is empty.'
  });
});

test('classifyNoStandingPriorityCondition still excludes docs maintenance with rollout-shaped wording', async () => {
  const result = await classifyNoStandingPriorityCondition('/tmp/repo', 'owner/repo', ['standing-priority'], {
    targetSlug: 'owner/repo',
    runGhList: () => ({
      status: 0,
      stdout: JSON.stringify([
        {
          number: 946,
          title: 'Upstream demo: refresh labview-icon-editor-demo docs',
          body: [
            'Update docs for released comparevi-history workflow files.',
            'Mention downstream forks for operator context.',
            'This is docs maintenance, not a rollout lane.'
          ].join('\n'),
          labels: []
        }
      ])
    }),
    runRestList: async () => ({ status: 'error', error: 'not-used' }),
    warn: () => {}
  });

  assert.deepEqual(result, {
    status: 'classified',
    reason: 'queue-empty',
    repository: 'owner/repo',
    openIssueCount: 1,
    message: 'No eligible in-scope open issues remain in owner/repo; the standing-priority queue is empty.'
  });
});

test('classifyNoStandingPriorityCondition treats blocked rollout trackers as queue-empty when issue detail confirms the block', async () => {
  const result = await classifyNoStandingPriorityCondition('/tmp/repo', 'owner/repo', ['standing-priority'], {
    targetSlug: 'owner/repo',
    runGhList: () => ({
      status: 0,
      stdout: JSON.stringify([
        {
          number: 946,
          title: 'Upstream demo: land released comparevi-history diagnostics in labview-icon-editor-demo',
          body: 'Track comparevi-history#23 as the blocker for the final public explicit-mode reviewer surface.',
          labels: []
        }
      ])
    }),
    fetchIssueDetailsFn: async (issueNumber) => ({
      number: issueNumber,
      title: 'Upstream demo: land released comparevi-history diagnostics in labview-icon-editor-demo',
      body: 'Track comparevi-history#23 as the blocker for the final public explicit-mode reviewer surface.',
      commentBodies: [
        'Standing-priority moved away because the remaining gap is externally blocked on comparevi-history#23 and this is no longer the top actionable coding lane.'
      ]
    }),
    externalIssueStateFetcher: buildExternalIssueStateFetcher(),
    runRestList: async () => ({ status: 'error', error: 'not-used' }),
    warn: () => {}
  });

  assert.deepEqual(result, {
    status: 'classified',
    reason: 'queue-empty',
    repository: 'owner/repo',
    openIssueCount: 1,
    message: 'No eligible in-scope open issues remain in owner/repo; the standing-priority queue is empty.'
  });
});

test('classifyNoStandingPriorityCondition keeps rollout trackers actionable when the external blocker is already closed', async () => {
  const result = await classifyNoStandingPriorityCondition('/tmp/repo', 'owner/repo', ['standing-priority'], {
    targetSlug: 'owner/repo',
    runGhList: () => ({
      status: 0,
      stdout: JSON.stringify([
        {
          number: 946,
          title: 'Upstream demo: land released comparevi-history diagnostics in labview-icon-editor-demo',
          body: 'Track comparevi-history#23 as the blocker for the final public explicit-mode reviewer surface.',
          labels: []
        }
      ])
    }),
    fetchIssueDetailsFn: async (issueNumber) => ({
      number: issueNumber,
      title: 'Upstream demo: land released comparevi-history diagnostics in labview-icon-editor-demo',
      body: 'Track comparevi-history#23 as the blocker for the final public explicit-mode reviewer surface.',
      commentBodies: [
        'Standing-priority moved away because the remaining gap is externally blocked on comparevi-history#23 and this is no longer the top actionable coding lane.'
      ]
    }),
    externalIssueStateFetcher: buildExternalIssueStateFetcher({ 23: 'closed' }),
    runRestList: async () => ({ status: 'error', error: 'not-used' }),
    warn: () => {}
  });

  assert.equal(result.status, 'classified');
  assert.equal(result.reason, 'label-missing');
  assert.equal(result.repository, 'owner/repo');
  assert.equal(result.openIssueCount, 1);
});

test('classifyNoStandingPriorityCondition treats explicit external-only tracking rollout issues as queue-empty after shared blockers close', async () => {
  const result = await classifyNoStandingPriorityCondition('/tmp/repo', 'owner/repo', ['standing-priority'], {
    targetSlug: 'owner/repo',
    runGhList: () => ({
      status: 0,
      stdout: JSON.stringify([
        {
          number: 930,
          title: 'Epic: route released comparevi workflows through downstream rollout gates',
          body: ['## Child tracks', '- #946', '- #947'].join('\n'),
          labels: ['program']
        },
        {
          number: 946,
          title: 'Upstream demo: land released comparevi-history diagnostics in labview-icon-editor-demo',
          body: [
            'The canonical upstream demo rollout already landed in LabVIEW-Community-CI-CD/labview-icon-editor-demo.',
            'This issue remains open only as local blocked tracking under epic #930.',
            'Under the current standing selector, this issue is blocked tracking, not an active local standing lane.'
          ].join('\n'),
          labels: []
        },
        {
          number: 947,
          title: 'Downstream fork: validate upstream-aligned comparevi-history diagnostics in svelderrainruiz/labview-icon-editor-demo',
          body: [
            'The remaining downstream fork-validation work is now tracked explicitly in the downstream demo repo.',
            'This issue remains open only as local blocked tracking under epic #930.',
            'Under the current standing selector, this issue is blocked tracking, not an active local standing lane.'
          ].join('\n'),
          labels: []
        }
      ])
    }),
    runRestList: async () => ({ status: 'error', error: 'not-used' }),
    warn: () => {}
  });

  assert.deepEqual(result, {
    status: 'classified',
    reason: 'queue-empty',
    repository: 'owner/repo',
    openIssueCount: 3,
    message: 'No eligible in-scope open issues remain in owner/repo; the standing-priority queue is empty.'
  });
});

test('classifyNoStandingPriorityCondition keeps explicit external-only tracking issues blocked when shared comparevi-history blockers are already closed', async () => {
  const result = await classifyNoStandingPriorityCondition('/tmp/repo', 'owner/repo', ['standing-priority'], {
    targetSlug: 'owner/repo',
    runGhList: () => ({
      status: 0,
      stdout: JSON.stringify([
        {
          number: 930,
          title: 'Epic: route released comparevi workflows through downstream rollout gates',
          body: ['## Child tracks', '- #946'].join('\n'),
          labels: ['program']
        },
        {
          number: 946,
          title: 'Upstream demo: land released comparevi-history diagnostics in labview-icon-editor-demo',
          body: [
            'This issue remains open only as local blocked tracking under epic #930.',
            'Blocked by LabVIEW-Community-CI-CD/comparevi-history#23.',
            'Under the current standing selector, this issue is blocked tracking, not an active local standing lane.'
          ].join('\n'),
          labels: []
        }
      ])
    }),
    fetchIssueDetailsFn: async (issueNumber) => ({
      number: issueNumber,
      title: 'Upstream demo: land released comparevi-history diagnostics in labview-icon-editor-demo',
      body: [
        'This issue remains open only as local blocked tracking under epic #930.',
        'Blocked by LabVIEW-Community-CI-CD/comparevi-history#23.',
        'Under the current standing selector, this issue is blocked tracking, not an active local standing lane.'
      ].join('\n'),
      commentBodies: []
    }),
    externalIssueStateFetcher: buildExternalIssueStateFetcher({ 23: 'closed' }),
    runRestList: async () => ({ status: 'error', error: 'not-used' }),
    warn: () => {}
  });

  assert.deepEqual(result, {
    status: 'classified',
    reason: 'queue-empty',
    repository: 'owner/repo',
    openIssueCount: 2,
    message: 'No eligible in-scope open issues remain in owner/repo; the standing-priority queue is empty.'
  });
});

test('classifyNoStandingPriorityCondition does not treat historical comment-only external-tracking notes as a live block', async () => {
  const rolloutBody = [
    'Land diagnostics workflows in LabVIEW-Community-CI-CD/labview-icon-editor-demo.',
    'Use released comparevi-history refs only.',
    'Keep the workflow shape fork-safe for downstream forks.',
    'Document how downstream forks should stay aligned to the canonical upstream surface.'
  ].join('\n');
  const result = await classifyNoStandingPriorityCondition('/tmp/repo', 'owner/repo', ['standing-priority'], {
    targetSlug: 'owner/repo',
    runGhList: () => ({
      status: 0,
      stdout: JSON.stringify([
        {
          number: 946,
          title: 'Upstream demo: land released comparevi-history diagnostics in labview-icon-editor-demo',
          body: rolloutBody,
          labels: []
        }
      ])
    }),
    fetchIssueDetailsFn: async (issueNumber) => ({
      number: issueNumber,
      title: 'Upstream demo: land released comparevi-history diagnostics in labview-icon-editor-demo',
      body: rolloutBody,
      commentBodies: [
        'Historical note: this issue was blocked tracking, not an active local standing lane during the comparevi-history#23 phase.'
      ]
    }),
    runRestList: async () => ({ status: 'error', error: 'not-used' }),
    warn: () => {}
  });

  assert.equal(result.status, 'classified');
  assert.equal(result.reason, 'label-missing');
  assert.equal(result.repository, 'owner/repo');
  assert.equal(result.openIssueCount, 1);
});

test('classifyNoStandingPriorityCondition treats current comment-only external-tracking notes as blocked', async () => {
  const rolloutBody = [
    'Land diagnostics workflows in LabVIEW-Community-CI-CD/labview-icon-editor-demo.',
    'Use released comparevi-history refs only.',
    'Keep the workflow shape fork-safe for downstream forks.',
    'Document how downstream forks should stay aligned to the canonical upstream surface.'
  ].join('\n');
  const result = await classifyNoStandingPriorityCondition('/tmp/repo', 'owner/repo', ['standing-priority'], {
    targetSlug: 'owner/repo',
    runGhList: () => ({
      status: 0,
      stdout: JSON.stringify([
        {
          number: 946,
          title: 'Upstream demo: land released comparevi-history diagnostics in labview-icon-editor-demo',
          body: rolloutBody,
          labels: []
        }
      ])
    }),
    fetchIssueDetailsFn: async (issueNumber) => ({
      number: issueNumber,
      title: 'Upstream demo: land released comparevi-history diagnostics in labview-icon-editor-demo',
      body: rolloutBody,
      commentBodies: [
        'This issue remains open only as local blocked tracking under epic #930.',
        'Under the current standing selector, this issue is blocked tracking, not an active local standing lane.'
      ]
    }),
    runRestList: async () => ({ status: 'error', error: 'not-used' }),
    warn: () => {}
  });

  assert.deepEqual(result, {
    status: 'classified',
    reason: 'queue-empty',
    repository: 'owner/repo',
    openIssueCount: 1,
    message: 'No eligible in-scope open issues remain in owner/repo; the standing-priority queue is empty.'
  });
});

test('classifyNoStandingPriorityCondition keeps rollout issues in scope when the current body reactivates the lane despite stale comment demotions', async () => {
  const rolloutBody = [
    'Current status: the rollout lane is active again.',
    'This issue no longer remains open only as local blocked tracking under epic #930.',
    'Keep the workflow shape fork-safe for downstream forks.'
  ].join('\n');
  const result = await classifyNoStandingPriorityCondition('/tmp/repo', 'owner/repo', ['standing-priority'], {
    targetSlug: 'owner/repo',
    runGhList: () => ({
      status: 0,
      stdout: JSON.stringify([
        {
          number: 946,
          title: 'Upstream demo: land released comparevi-history diagnostics in labview-icon-editor-demo',
          body: rolloutBody,
          labels: []
        }
      ])
    }),
    fetchIssueDetailsFn: async (issueNumber) => ({
      number: issueNumber,
      title: 'Upstream demo: land released comparevi-history diagnostics in labview-icon-editor-demo',
      body: rolloutBody,
      commentBodies: [
        'This issue remains open only as local blocked tracking under epic #930.',
        'Under the current standing selector, this issue is blocked tracking, not an active local standing lane.'
      ]
    }),
    runRestList: async () => ({ status: 'error', error: 'not-used' }),
    warn: () => {}
  });

  assert.equal(result.status, 'classified');
  assert.equal(result.reason, 'label-missing');
  assert.equal(result.repository, 'owner/repo');
  assert.equal(result.openIssueCount, 1);
});

test('classifyNoStandingPriorityCondition keeps explicitly reactivated rollout issues in scope after negating blocked-tracking wording', async () => {
  const rolloutBody = [
    'Current status: the rollout lane is active again.',
    'This issue no longer remains open only as local blocked tracking under epic #930.',
    'Keep the workflow shape fork-safe for downstream forks.'
  ].join('\n');
  const result = await classifyNoStandingPriorityCondition('/tmp/repo', 'owner/repo', ['standing-priority'], {
    targetSlug: 'owner/repo',
    runGhList: () => ({
      status: 0,
      stdout: JSON.stringify([
        {
          number: 946,
          title: 'Upstream demo: land released comparevi-history diagnostics in labview-icon-editor-demo',
          body: rolloutBody,
          labels: []
        }
      ])
    }),
    fetchIssueDetailsFn: async (issueNumber) => ({
      number: issueNumber,
      title: 'Upstream demo: land released comparevi-history diagnostics in labview-icon-editor-demo',
      body: rolloutBody,
      commentBodies: []
    }),
    runRestList: async () => ({ status: 'error', error: 'not-used' }),
    warn: () => {}
  });

  assert.equal(result.status, 'classified');
  assert.equal(result.reason, 'label-missing');
  assert.equal(result.repository, 'owner/repo');
  assert.equal(result.openIssueCount, 1);
});

test('classifyNoStandingPriorityCondition keeps rollout trackers in scope when detail only reports a non-external blocker', async () => {
  const result = await classifyNoStandingPriorityCondition('/tmp/repo', 'owner/repo', ['standing-priority'], {
    targetSlug: 'owner/repo',
    runGhList: () => ({
      status: 0,
      stdout: JSON.stringify([
        {
          number: 946,
          title: 'Upstream demo: land released comparevi-history diagnostics in labview-icon-editor-demo',
          body: 'Track comparevi-history#23 as the blocker for the final public explicit-mode reviewer surface.',
          labels: []
        }
      ])
    }),
    fetchIssueDetailsFn: async (issueNumber) => ({
      number: issueNumber,
      title: 'Upstream demo: land released comparevi-history diagnostics in labview-icon-editor-demo',
      body: 'Track comparevi-history#23 as the blocker for the final public explicit-mode reviewer surface.',
      commentBodies: ['Blocked by fixture drift cleanup before landing.']
    }),
    runRestList: async () => ({ status: 'error', error: 'not-used' }),
    warn: () => {}
  });

  assert.equal(result.status, 'classified');
  assert.equal(result.reason, 'label-missing');
  assert.equal(result.repository, 'owner/repo');
  assert.equal(result.openIssueCount, 1);
});

test('classifyNoStandingPriorityCondition treats umbrella fallback queues with only blocked concrete children as queue-empty', async () => {
  const result = await classifyNoStandingPriorityCondition('/tmp/repo', 'owner/repo', ['standing-priority'], {
    targetSlug: 'owner/repo',
    runGhList: () => ({
      status: 0,
      stdout: JSON.stringify([
        {
          number: 930,
          title: 'Epic: route released comparevi workflows through downstream rollout gates',
          body: ['## Child tracks', '- #946', '- #947'].join('\n'),
          labels: ['program']
        },
        {
          number: 946,
          title: '[P1] upstream rollout child',
          body: ['Parent epic: #930', 'The remaining work is externally blocked on comparevi-history#23.'].join('\n'),
          labels: []
        },
        {
          number: 947,
          title: '[P1] downstream rollout child',
          body: ['Parent epic: #930', 'The remaining work is externally blocked on comparevi-history#23.'].join('\n'),
          labels: []
        }
      ])
    }),
    fetchIssueDetailsFn: async (issueNumber) => ({
      number: issueNumber,
      title: issueNumber === 946 ? '[P1] upstream rollout child' : '[P1] downstream rollout child',
      body: ['Parent epic: #930', 'The remaining work is externally blocked on comparevi-history#23.'].join('\n'),
      commentBodies: []
    }),
    externalIssueStateFetcher: buildExternalIssueStateFetcher(),
    runRestList: async () => ({ status: 'error', error: 'not-used' }),
    warn: () => {}
  });

  assert.deepEqual(result, {
    status: 'classified',
    reason: 'queue-empty',
    repository: 'owner/repo',
    openIssueCount: 3,
    message: 'No eligible in-scope open issues remain in owner/repo; the standing-priority queue is empty.'
  });
});

test('classifyNoStandingPriorityCondition fails closed when rollout detail cannot hydrate comments', async () => {
  const rolloutBody = [
    'Land the released comparevi-history diagnostics workflow files in the upstream demo repo.',
    'Keep PR head repo/ref routing fork-safe for downstream mirrors.',
    'Track comparevi-history#23 as the remaining explicit-mode renderer dependency.'
  ].join('\n');
  await assert.rejects(
    () =>
      classifyNoStandingPriorityCondition('/tmp/repo', 'owner/repo', ['standing-priority'], {
        targetSlug: 'owner/repo',
        runGhList: () => ({
          status: 0,
          stdout: JSON.stringify([
            {
              number: 946,
              title: 'Upstream demo: land released comparevi-history diagnostics in labview-icon-editor-demo',
              body: rolloutBody,
              labels: []
            }
          ])
        }),
        fetchIssueDetailsFn: async (issueNumber) => ({
          number: issueNumber,
          title: 'Upstream demo: land released comparevi-history diagnostics in labview-icon-editor-demo',
          body: rolloutBody,
          commentCount: 2,
          commentBodies: []
        }),
        runRestList: async () => ({ status: 'error', error: 'not-used' }),
        warn: () => {}
      }),
    /did not hydrate comment bodies/i
  );
});

test('autoSelectStandingPriorityIssue skips blocked rollout trackers when issue detail confirms the block', async () => {
  const calls = [];
  const result = await autoSelectStandingPriorityIssue('/tmp/repo', 'owner/repo', {
    targetSlug: 'owner/repo',
    runGhList: () => ({
      status: 0,
      stdout: JSON.stringify([
        {
          number: 946,
          title: '[P0] Upstream demo: land released comparevi-history diagnostics in labview-icon-editor-demo',
          body: 'Track comparevi-history#23 as the blocker for the final public explicit-mode reviewer surface.',
          labels: [],
          createdAt: '2026-03-01T00:00:00Z'
        },
        {
          number: 951,
          title: '[P1] actionable follow-up',
          body: 'Remaining in-repo work.',
          labels: [],
          createdAt: '2026-03-02T00:00:00Z'
        }
      ])
    }),
    fetchIssueDetailsFn: async (issueNumber) =>
      issueNumber === 946
        ? {
            number: 946,
            title: '[P0] Upstream demo: land released comparevi-history diagnostics in labview-icon-editor-demo',
            body: 'Track comparevi-history#23 as the blocker for the final public explicit-mode reviewer surface.',
            commentBodies: [
              'Standing-priority moved away because the remaining gap is externally blocked on comparevi-history#23 and this is no longer the top actionable coding lane.'
            ]
          }
        : {
            number: 951,
            title: '[P1] actionable follow-up',
            body: 'Remaining in-repo work.',
            commentBodies: []
          },
    externalIssueStateFetcher: buildExternalIssueStateFetcher(),
    runGhAddLabel: ({ issueNumber }) => {
      calls.push(issueNumber);
      return { status: 0, stdout: '' };
    },
    runRestList: async () => ({ status: 'error', error: 'not-used' }),
    runRestAddLabel: async () => ({ status: 'error', error: 'not-used' }),
    warn: () => {}
  });

  assert.equal(result.status, 'selected');
  assert.equal(result.issue?.number, 951);
  assert.deepEqual(calls, [951]);
});

test('autoSelectStandingPriorityIssue promotes rollout trackers once the external blocker is closed', async () => {
  const calls = [];
  const result = await autoSelectStandingPriorityIssue('/tmp/repo', 'owner/repo', {
    targetSlug: 'owner/repo',
    runGhList: () => ({
      status: 0,
      stdout: JSON.stringify([
        {
          number: 946,
          title: '[P0] Upstream demo: land released comparevi-history diagnostics in labview-icon-editor-demo',
          body: 'Track comparevi-history#23 as the blocker for the final public explicit-mode reviewer surface.',
          labels: [],
          createdAt: '2026-03-01T00:00:00Z'
        },
        {
          number: 951,
          title: '[P1] actionable follow-up',
          body: 'Remaining in-repo work.',
          labels: [],
          createdAt: '2026-03-02T00:00:00Z'
        }
      ])
    }),
    fetchIssueDetailsFn: async (issueNumber) =>
      issueNumber === 946
        ? {
            number: 946,
            title: '[P0] Upstream demo: land released comparevi-history diagnostics in labview-icon-editor-demo',
            body: 'Track comparevi-history#23 as the blocker for the final public explicit-mode reviewer surface.',
            commentBodies: [
              'Standing-priority moved away because the remaining gap is externally blocked on comparevi-history#23 and this is no longer the top actionable coding lane.'
            ]
          }
        : {
            number: 951,
            title: '[P1] actionable follow-up',
            body: 'Remaining in-repo work.',
            commentBodies: []
          },
    externalIssueStateFetcher: buildExternalIssueStateFetcher({ 23: 'closed' }),
    runGhAddLabel: ({ issueNumber }) => {
      calls.push(issueNumber);
      return { status: 0, stdout: '' };
    },
    runRestList: async () => ({ status: 'error', error: 'not-used' }),
    runRestAddLabel: async () => ({ status: 'error', error: 'not-used' }),
    warn: () => {}
  });

  assert.equal(result.status, 'selected');
  assert.equal(result.issue?.number, 946);
  assert.deepEqual(calls, [946]);
});

test('autoSelectStandingPriorityIssue reports empty when only blocked concrete children remain behind an umbrella fallback', async () => {
  const calls = [];
  const result = await autoSelectStandingPriorityIssue('/tmp/repo', 'owner/repo', {
    targetSlug: 'owner/repo',
    runGhList: () => ({
      status: 0,
      stdout: JSON.stringify([
        {
          number: 930,
          title: 'Epic: route released comparevi workflows through downstream rollout gates',
          body: ['## Child tracks', '- #946', '- #947'].join('\n'),
          labels: ['program'],
          createdAt: '2026-03-01T00:00:00Z'
        },
        {
          number: 946,
          title: '[P1] upstream rollout child',
          body: ['Parent epic: #930', 'The remaining work is externally blocked on comparevi-history#23.'].join('\n'),
          labels: [],
          createdAt: '2026-03-02T00:00:00Z'
        },
        {
          number: 947,
          title: '[P1] downstream rollout child',
          body: ['Parent epic: #930', 'The remaining work is externally blocked on comparevi-history#23.'].join('\n'),
          labels: [],
          createdAt: '2026-03-03T00:00:00Z'
        }
      ])
    }),
    fetchIssueDetailsFn: async (issueNumber) => ({
      number: issueNumber,
      title: issueNumber === 946 ? '[P1] upstream rollout child' : '[P1] downstream rollout child',
      body: ['Parent epic: #930', 'The remaining work is externally blocked on comparevi-history#23.'].join('\n'),
      commentBodies: []
    }),
    externalIssueStateFetcher: buildExternalIssueStateFetcher(),
    runGhAddLabel: ({ issueNumber }) => {
      calls.push(issueNumber);
      return { status: 0, stdout: '' };
    },
    runRestList: async () => ({ status: 'error', error: 'not-used' }),
    runRestAddLabel: async () => ({ status: 'error', error: 'not-used' }),
    warn: () => {}
  });

  assert.deepEqual(result, {
    status: 'empty',
    source: 'gh',
    repoSlug: 'owner/repo',
    openIssueCount: 3
  });
  assert.deepEqual(calls, []);
});

test('classifyNoStandingPriorityCondition fails closed when external blocker hydration fails', async () => {
  const warnings = [];
  const result = await classifyNoStandingPriorityCondition('/tmp/repo', 'owner/repo', ['standing-priority'], {
    targetSlug: 'owner/repo',
    runGhList: () => ({
      status: 0,
      stdout: JSON.stringify([
        {
          number: 946,
          title: 'Upstream demo: land released comparevi-history diagnostics in labview-icon-editor-demo',
          body: 'Track comparevi-history#23 as the blocker for the final public explicit-mode reviewer surface.',
          labels: []
        }
      ])
    }),
    fetchIssueDetailsFn: async (issueNumber) => ({
      number: issueNumber,
      title: 'Upstream demo: land released comparevi-history diagnostics in labview-icon-editor-demo',
      body: 'Track comparevi-history#23 as the blocker for the final public explicit-mode reviewer surface.',
      commentBodies: [
        'Standing-priority moved away because the remaining gap is externally blocked on comparevi-history#23 and this is no longer the top actionable coding lane.'
      ]
    }),
    externalIssueStateFetcher: buildExternalIssueStateFetcher({
      23: new Error('comparevi-history lookup failed')
    }),
    runRestList: async () => ({ status: 'error', error: 'not-used' }),
    warn: (message) => warnings.push(message)
  });

  assert.deepEqual(result, {
    status: 'classified',
    reason: 'queue-empty',
    repository: 'owner/repo',
    openIssueCount: 1,
    message: 'No eligible in-scope open issues remain in owner/repo; the standing-priority queue is empty.'
  });
  assert.match(warnings.join('\n'), /external blocker state hydration failed/i);
  assert.match(warnings.join('\n'), /comparevi-history lookup failed/i);
});

test('classifyNoStandingPriorityCondition keeps excluded-label queues as label-missing', async () => {
  const result = await classifyNoStandingPriorityCondition('/tmp/repo', 'owner/repo', ['standing-priority'], {
    targetSlug: 'owner/repo',
    runGhList: () => ({
      status: 0,
      stdout: JSON.stringify([
        {
          number: 980,
          title: '[P1] duplicate backlog item',
          labels: ['duplicate']
        }
      ])
    }),
    runRestList: async () => ({ status: 'error', error: 'not-used' }),
    warn: () => {}
  });

  assert.equal(result.status, 'classified');
  assert.equal(result.reason, 'label-missing');
  assert.equal(result.repository, 'owner/repo');
  assert.equal(result.openIssueCount, 1);
  assert.match(result.message, /none carry the checked standing-priority labels/i);
});

test('classifyNoStandingPriorityCondition keeps excluded blocked rollout queues as label-missing', async () => {
  const result = await classifyNoStandingPriorityCondition('/tmp/repo', 'owner/repo', ['standing-priority'], {
    targetSlug: 'owner/repo',
    runGhList: () => ({
      status: 0,
      stdout: JSON.stringify([
        {
          number: 980,
          title: 'Land released comparevi-history diagnostics workflow files in upstream demo intake',
          body: 'Track comparevi-history#23 as the blocker for the final public explicit-mode reviewer surface.',
          labels: ['duplicate']
        }
      ])
    }),
    fetchIssueDetailsFn: async (issueNumber) => ({
      number: issueNumber,
      title: 'Land released comparevi-history diagnostics workflow files in upstream demo intake',
      body: 'Track comparevi-history#23 as the blocker for the final public explicit-mode reviewer surface.',
      commentBodies: [
        'Standing-priority moved away because the remaining gap is externally blocked on comparevi-history#23 and this is no longer the top actionable coding lane.'
      ]
    }),
    runRestList: async () => ({ status: 'error', error: 'not-used' }),
    warn: () => {}
  });

  assert.equal(result.status, 'classified');
  assert.equal(result.reason, 'label-missing');
  assert.equal(result.repository, 'owner/repo');
  assert.equal(result.openIssueCount, 1);
});
test('classifyNoStandingPriorityCondition treats out-of-scope demo queues with excluded labels as label-missing', async () => {
  const result = await classifyNoStandingPriorityCondition('/tmp/repo', 'owner/repo', ['standing-priority'], {
    targetSlug: 'owner/repo',
    runGhList: () => ({
      status: 0,
      stdout: JSON.stringify([
        {
          number: 946,
          title: 'Upstream demo: update icon editor assets in labview-icon-editor-demo',
          labels: ['duplicate']
        }
      ])
    }),
    runRestList: async () => ({ status: 'error', error: 'not-used' }),
    warn: () => {}
  });

  assert.deepEqual(result, {
    status: 'classified',
    reason: 'label-missing',
    repository: 'owner/repo',
    openIssueCount: 1,
    message: 'owner/repo has 1 open issue, but none carry the checked standing-priority labels (`standing-priority`).'
  });
});

test('buildMultipleStandingPriorityReport emits deterministic schema payload', () => {
  const report = buildMultipleStandingPriorityReport({
    message: 'Multiple open standing-priority issues found',
    labels: ['standing-priority'],
    repository: 'owner/repo',
    issueNumbers: [743, 732],
    failOnMultiple: true,
    generatedAt: '2026-03-06T02:00:00.000Z'
  });

  assert.deepEqual(report, {
    schema: 'standing-priority/multiple-standing@v1',
    generatedAt: '2026-03-06T02:00:00.000Z',
    repository: 'owner/repo',
    labels: ['standing-priority'],
    issueNumbers: [743, 732],
    message: 'Multiple open standing-priority issues found',
    failOnMultiple: true
  });
});


test('resolveUpstreamRepositorySlug prefers upstream remote when fork slug is active', async (t) => {
  const repoRoot = await mkdtemp(path.join(tmpdir(), 'standing-upstream-'));
  t.after(() => rm(repoRoot, { recursive: true, force: true }));

  const gitDir = path.join(repoRoot, '.git');
  await mkdir(gitDir, { recursive: true });
  await writeFile(
    path.join(gitDir, 'config'),
    '[remote "origin"]\n  url = https://github.com/svelderrainruiz/compare-vi-cli-action.git\n[remote "upstream"]\n  url = https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action.git\n',
    'utf8'
  );

  const upstream = resolveUpstreamRepositorySlug(repoRoot, 'svelderrainruiz/compare-vi-cli-action');
  assert.equal(upstream, 'LabVIEW-Community-CI-CD/compare-vi-cli-action');
});

test('resolveUpstreamRepositorySlug returns null when upstream remote is missing', async (t) => {
  const repoRoot = await mkdtemp(path.join(tmpdir(), 'standing-upstream-fallback-'));
  t.after(() => rm(repoRoot, { recursive: true, force: true }));

  const gitDir = path.join(repoRoot, '.git');
  await mkdir(gitDir, { recursive: true });
  await writeFile(
    path.join(gitDir, 'config'),
    '[remote "origin"]\n  url = https://github.com/svelderrainruiz/compare-vi-cli-action.git\n',
    'utf8'
  );

  const upstream = resolveUpstreamRepositorySlug(repoRoot, 'svelderrainruiz/compare-vi-cli-action');
  assert.equal(upstream, null);
});

test('resolveUpstreamRepositorySlug honors explicit env override', async (t) => {
  const repoRoot = await mkdtemp(path.join(tmpdir(), 'standing-upstream-env-'));
  t.after(() => rm(repoRoot, { recursive: true, force: true }));

  const upstream = resolveUpstreamRepositorySlug(
    repoRoot,
    'fork-owner/compare-vi-cli-action',
    { AGENT_PRIORITY_UPSTREAM_REPOSITORY: 'upstream-owner/compare-vi-cli-action' }
  );
  assert.equal(upstream, 'upstream-owner/compare-vi-cli-action');
});

test('resolveStandingPriorityRepositorySlug prefers the canonical upstream slug for fork worktrees', async (t) => {
  const repoRoot = await mkdtemp(path.join(tmpdir(), 'standing-repo-slug-'));
  t.after(() => rm(repoRoot, { recursive: true, force: true }));

  await mkdir(path.join(repoRoot, '.git'), { recursive: true });
  await writeFile(
    path.join(repoRoot, '.git', 'config'),
    '[remote "origin"]\n  url = https://github.com/svelderrainruiz/compare-vi-cli-action.git\n[remote "upstream"]\n  url = https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action.git\n',
    'utf8'
  );

  const slug = resolveStandingPriorityRepositorySlug(repoRoot, {
    GITHUB_REPOSITORY: 'svelderrainruiz/compare-vi-cli-action'
  });

  assert.equal(slug, 'LabVIEW-Community-CI-CD/compare-vi-cli-action');
});

test('resolveStandingPriorityLookupPlan checks upstream when fork lookup reports empty', async () => {
  const calls = [];
  const warnings = [];
  const resolveForRepo = async (_repoRoot, targetSlug, labels) => {
    calls.push({ targetSlug, labels });
    if (calls.length === 1) {
      return {
        found: null,
        ghOutcome: { status: 'empty' },
        restOutcome: { status: 'empty' },
        repoSlug: targetSlug
      };
    }

    return {
      found: {
        number: 321,
        label: 'standing-priority',
        repoSlug: targetSlug,
        source: 'mock'
      },
      ghOutcome: { status: 'found', label: 'standing-priority' },
      restOutcome: { status: 'unavailable', error: 'not-used' },
      repoSlug: targetSlug
    };
  };

  const result = await resolveStandingPriorityLookupPlan({
    repoRoot: '/tmp/repo',
    slug: 'fork-owner/compare-vi-cli-action',
    standingPriorityLabels: ['fork-standing-priority', 'standing-priority'],
    resolveForRepo,
    resolveUpstreamSlug: () => 'labview-community-ci-cd/compare-vi-cli-action',
    warn: (message) => warnings.push(message)
  });

  assert.equal(result.found?.number, 321);
  assert.equal(calls.length, 2);
  assert.deepEqual(calls[0], {
    targetSlug: 'fork-owner/compare-vi-cli-action',
    labels: ['fork-standing-priority', 'standing-priority']
  });
  assert.deepEqual(calls[1], {
    targetSlug: 'labview-community-ci-cd/compare-vi-cli-action',
    labels: ['standing-priority']
  });
  assert.equal(warnings.length, 1);
});

test('gitRoot uses injected fallback root when git rev-parse is unavailable', async (t) => {
  const repoRoot = await mkdtemp(path.join(tmpdir(), 'priority-gitroot-'));
  t.after(() => rm(repoRoot, { recursive: true, force: true }));
  await writeFile(path.join(repoRoot, 'package.json'), '{}\n', 'utf8');

  const warnings = [];
  const resolved = gitRoot({
    commandRunner: () => ({ status: 1, stdout: '', stderr: 'fatal: not a git repository', error: { code: 'EPERM' } }),
    fallbackRoot: repoRoot,
    warn: (message) => warnings.push(message)
  });

  assert.equal(resolved, repoRoot);
  assert.equal(warnings.length, 1);
});

test('resolveStandingPriorityForRepo accepts injected GH/REST transports', async () => {
  const calls = [];
  const result = await resolveStandingPriorityForRepo(
    '/tmp/repo',
    'fork-owner/compare-vi-cli-action',
    ['fork-standing-priority', 'standing-priority'],
    {
      runGhList: async ({ slug, label }) => {
        calls.push({ type: 'gh', slug, label });
        return { status: 0, stdout: '[]', stderr: '' };
      },
      runRestLookup: async ({ slug, standingPriorityLabels }) => {
        calls.push({ type: 'rest', slug, labels: standingPriorityLabels });
        return {
          status: 'found',
          number: 777,
          label: 'standing-priority',
          repoSlug: slug
        };
      },
      warn: () => {}
    }
  );

  assert.equal(result.found?.number, 777);
  assert.equal(calls.filter((entry) => entry.type === 'gh').length, 2);
  assert.equal(calls.filter((entry) => entry.type === 'rest').length, 1);
});

test('fetchIssue uses injected ghIssueFetcher before restIssueFetcher', async () => {
  const calls = [];
  const issue = await fetchIssue(41, '/tmp/repo', 'fork-owner/compare-vi-cli-action', {
    ghIssueFetcher: async ({ args }) => {
      calls.push(['gh', args[0]]);
      return {
        number: 41,
        title: 'Injected GH Issue',
        state: 'open',
        updatedAt: '2026-03-01T00:00:00Z',
        url: 'https://github.com/fork-owner/compare-vi-cli-action/issues/41',
        labels: [{ name: 'standing-priority' }],
        assignees: [{ login: 'agent' }],
        milestone: { title: 'M1' },
        comments: [{ body: 'first' }, { body: 'second' }],
        body: 'body'
      };
    },
    restIssueFetcher: async () => {
      calls.push(['rest']);
      return null;
    }
  });

  assert.equal(issue.number, 41);
  assert.deepEqual(issue.labels, ['standing-priority']);
  assert.deepEqual(issue.assignees, ['agent']);
  assert.deepEqual(issue.commentBodies, ['first', 'second']);
  assert.equal(calls.some((entry) => entry[0] === 'rest'), false);
});

test('fetchIssue enriches numeric gh comment counts with issue-view comment bodies before REST fallback', async () => {
  const calls = [];
  const issue = await fetchIssue(43, '/tmp/repo', 'fork-owner/compare-vi-cli-action', {
    ghIssueFetcher: async ({ args }) => {
      calls.push(args[0]);
      if (args[0] === 'api') {
        return {
          number: 43,
          title: 'API-first issue',
          state: 'open',
          updatedAt: '2026-03-03T00:00:00Z',
          url: 'https://github.com/fork-owner/compare-vi-cli-action/issues/43',
          labels: [{ name: 'standing-priority' }],
          assignees: [{ login: 'agent' }],
          milestone: { title: 'M3' },
          comments: 2,
          body: 'body'
        };
      }
      return {
        number: 43,
        title: 'API-first issue',
        state: 'open',
        updatedAt: '2026-03-03T00:00:00Z',
        url: 'https://github.com/fork-owner/compare-vi-cli-action/issues/43',
        labels: [{ name: 'standing-priority' }],
        assignees: [{ login: 'agent' }],
        milestone: { title: 'M3' },
        comments: [{ body: 'blocked comment' }, { body: 'follow-up comment' }],
        body: 'body'
      };
    },
    restIssueFetcher: async () => {
      throw new Error('rest should not be used');
    }
  });

  assert.equal(issue.number, 43);
  assert.deepEqual(issue.commentBodies, ['blocked comment', 'follow-up comment']);
  assert.deepEqual(calls, ['api', 'issue']);
});

test('fetchIssue falls back to REST hydration when issue-view comment enrichment fails after gh api success', async () => {
  const calls = [];
  const issue = await fetchIssue(44, '/tmp/repo', 'fork-owner/compare-vi-cli-action', {
    ghIssueFetcher: async ({ args }) => {
      calls.push(args[0]);
      if (args[0] === 'api') {
        return {
          number: 44,
          title: 'API-first issue',
          state: 'open',
          updatedAt: '2026-03-04T00:00:00Z',
          url: 'https://github.com/fork-owner/compare-vi-cli-action/issues/44',
          labels: [{ name: 'standing-priority' }],
          assignees: [{ login: 'agent' }],
          milestone: { title: 'M4' },
          comments: 2,
          body: 'body'
        };
      }
      return null;
    },
    restIssueFetcher: async () => {
      calls.push('rest');
      return {
        number: 44,
        title: 'REST-hydrated issue',
        state: 'open',
        updated_at: '2026-03-04T00:00:00Z',
        html_url: 'https://github.com/fork-owner/compare-vi-cli-action/issues/44',
        labels: [{ name: 'standing-priority' }],
        assignees: [{ login: 'agent' }],
        milestone: { title: 'M4' },
        comments: [{ body: 'hydrated by rest' }, { body: 'rest follow-up' }],
        body: 'body'
      };
    }
  });

  assert.equal(issue.number, 44);
  assert.deepEqual(issue.commentBodies, ['hydrated by rest', 'rest follow-up']);
  assert.deepEqual(calls, ['api', 'issue', 'rest']);
});

test('fetchIssue preserves updatedAt from the gh api fast path when no comment hydration is needed', async () => {
  const calls = [];
  const issue = await fetchIssue(45, '/tmp/repo', 'fork-owner/compare-vi-cli-action', {
    ghIssueFetcher: async ({ args }) => {
      calls.push(args[0]);
      if (args[0] !== 'api') {
        throw new Error('issue view should not be used');
      }
      return {
        number: 45,
        title: 'API-fast-path issue',
        state: 'open',
        updated_at: '2026-03-05T00:00:00Z',
        url: 'https://github.com/fork-owner/compare-vi-cli-action/issues/45',
        html_url: 'https://github.com/fork-owner/compare-vi-cli-action/issues/45',
        labels: [{ name: 'standing-priority' }],
        assignees: [{ login: 'agent' }],
        milestone: { title: 'M5' },
        comments: 0,
        body: 'body'
      };
    },
    restIssueFetcher: async () => {
      throw new Error('rest should not be used');
    }
  });

  assert.equal(issue.number, 45);
  assert.equal(issue.updatedAt, '2026-03-05T00:00:00Z');
  assert.deepEqual(calls, ['api']);
});

test('fetchIssue falls back to injected restIssueFetcher when GH fetcher returns null', async () => {
  const issue = await fetchIssue(42, '/tmp/repo', 'fork-owner/compare-vi-cli-action', {
    ghIssueFetcher: async () => null,
    restIssueFetcher: async () => ({
      number: 42,
      title: 'Injected REST Issue',
      state: 'open',
      updated_at: '2026-03-02T00:00:00Z',
      html_url: 'https://github.com/fork-owner/compare-vi-cli-action/issues/42',
      labels: [{ name: 'fork-standing-priority' }],
      assignees: [{ login: 'fallback' }],
      milestone: { title: 'M2' },
      comments: 2,
      body: 'rest body'
    })
  });

  assert.equal(issue.number, 42);
  assert.deepEqual(issue.labels, ['fork-standing-priority']);
  assert.deepEqual(issue.assignees, ['fallback']);
});

test('computeNextPriorityCacheState returns deterministic cache projection', () => {
  const next = computeNextPriorityCacheState({
    cache: {
      repository: 'old/repo',
      title: 'Old',
      labels: ['old-label'],
      assignees: ['old-user']
    },
    number: 9,
    issueRepoSlug: 'new/repo',
    snapshot: {
      title: 'New title',
      url: 'https://example.test/issues/9',
      state: 'OPEN',
      labels: ['standing-priority'],
      assignees: ['agent'],
      milestone: null,
      commentCount: 3,
      updatedAt: '2026-03-03T00:00:00Z',
      digest: 'digest',
      bodyDigest: 'body-digest',
      mirrorOf: {
        repository: 'upstream/repo',
        number: 966,
        url: 'https://github.com/upstream/repo/issues/966'
      }
    },
    fetchSource: 'cache',
    fetchError: 'none',
    cachedAtUtc: '2026-03-04T00:00:00Z'
  });

  assert.equal(next.repository, 'new/repo');
  assert.equal(next.number, 9);
  assert.deepEqual(next.labels, ['standing-priority']);
  assert.equal(next.lastFetchSource, 'cache');
  assert.equal(next.cachedAtUtc, '2026-03-04T00:00:00Z');
  assert.equal(next.mirrorOf.number, 966);
});

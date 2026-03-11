#!/usr/bin/env node

import test from 'node:test';
import assert from 'node:assert/strict';

import { buildCodexTurnPrompt } from '../run-delivery-turn-with-codex.mjs';

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
  assert.match(prompt, /returning only JSON/i);
});

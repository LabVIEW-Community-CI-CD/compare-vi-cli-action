import test from 'node:test';
import assert from 'node:assert/strict';
import { normalizeSummary } from '../core/summary-utils.mjs';

test('normalizeSummary zeroes timestamp and duration and sorts steps', () => {
  const input = {
    schema: 'comparevi/hooks-summary@v1',
    hook: 'pre-commit',
    timestamp: '2025-10-13T12:34:56Z',
    steps: [
      {
        name: 'b-step',
        durationMs: 42,
        status: 'ok',
        stdout: '[ni-container-compare] running container=ni-compare-a elapsed=15.7s timeout=240s\r\nkeep-me',
      },
      {
        name: 'a-step',
        durationMs: 5,
        status: 'ok',
        stderr: '[ni-linux-container-compare] running container=ni-linux elapsed=31s timeout=240s\r\nwarn-me',
      },
    ],
  };

  const normalized = normalizeSummary(input);

  assert.equal(normalized.timestamp, 'normalized');
  assert.deepEqual(
    normalized.steps,
    [
      { name: 'a-step', durationMs: 0, status: 'ok', stderr: 'warn-me', stdout: undefined },
      { name: 'b-step', durationMs: 0, status: 'ok', stdout: 'keep-me', stderr: undefined },
    ],
  );

  // Ensure original input not mutated
  assert.equal(input.timestamp, '2025-10-13T12:34:56Z');
  assert.equal(input.steps[0].durationMs, 42);
});

test('normalizeSummary removes volatile JSON timestamps and one-time bootstrap noise from step output', () => {
  const input = {
    schema: 'comparevi/hooks-summary@v1',
    hook: 'pre-push',
    timestamp: '2026-03-14T04:39:08.869Z',
    steps: [
      {
        name: 'agent-review-policy',
        durationMs: 27,
        status: 'ok',
        stdout: JSON.stringify({
          generatedAt: '2026-03-14T04:39:08.869Z',
          overall: {
            status: 'passed'
          },
          providers: {
            simulation: {
              startedAt: '2026-03-14T04:39:08.100Z',
              finishedAt: '2026-03-14T04:39:08.200Z',
              durationMs: 100
            }
          }
        }, null, 2)
      },
      {
        name: 'pre-push-checks',
        durationMs: 31,
        status: 'ok',
        stdout: [
          'Downloading actionlint 1.7.7 (actionlint_1.7.7_windows_amd64.zip)...',
          '[pre-push] actionlint OK'
        ].join('\n')
      }
    ]
  };

  const normalized = normalizeSummary(input);
  assert.equal(normalized.steps[0].stdout.includes('"generatedAt": "normalized"'), true);
  assert.equal(normalized.steps[0].stdout.includes('"startedAt": "normalized"'), true);
  assert.equal(normalized.steps[0].stdout.includes('"finishedAt": "normalized"'), true);
  assert.equal(normalized.steps[0].stdout.includes('"durationMs": 0'), true);
  assert.equal(normalized.steps[1].stdout, '[pre-push] actionlint OK');
});

import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

import { buildOperatorSteeringEvent, parseArgs, runOperatorSteeringEvent } from '../operator-steering-event.mjs';

function writeJson(filePath, payload) {
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
  fs.writeFileSync(filePath, `${JSON.stringify(payload, null, 2)}\n`, 'utf8');
}

function createFixtureRoot(name) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), `${name}-`));
  fs.mkdirSync(path.join(root, 'tests', 'results', '_agent', 'runtime'), { recursive: true });
  fs.mkdirSync(path.join(root, 'tests', 'results', '_agent', 'handoff'), { recursive: true });
  fs.mkdirSync(path.join(root, 'tests', 'results', '_agent', 'cost', 'invoice-turns'), { recursive: true });
  return root;
}

function writeContinuity(root, overrides = {}) {
  const payload = {
    schema: 'priority/continuity-telemetry-report@v1',
    generatedAt: '2026-03-21T23:10:00.000Z',
    repoRoot: root,
    status: 'at-risk',
    issueContext: {
      mode: 'issue',
      issue: 1696,
      present: true,
      fresh: true,
      observedAt: '2026-03-21T23:09:00.000Z',
      reason: null
    },
    continuity: {
      status: 'at-risk',
      preservedWithoutPrompt: true,
      promptDependency: 'medium',
      unattendedSignalCount: 4,
      quietPeriod: {
        status: 'degrading',
        continuityReferenceAt: '2026-03-21T23:09:00.000Z',
        silenceGapSeconds: 0,
        operatorQuietPeriodTreatedAsPause: true
      },
      turnBoundary: {
        status: 'active-work-pending',
        operatorTurnEndWouldCreateIdleGap: true,
        activeLaneIssue: 1696,
        wakeCondition: 'merge-attempt',
        source: 'delivery-state',
        reason: 'standing issue #1696 still has active work pending'
      },
      recommendation: 'keep the live lane active or hand the standing lane to a background worker before ending the turn'
    }
  };
  writeJson(path.join(root, 'tests', 'results', '_agent', 'runtime', 'continuity-telemetry.json'), {
    ...payload,
    ...overrides,
    continuity: {
      ...payload.continuity,
      ...(overrides.continuity || {}),
      quietPeriod: {
        ...payload.continuity.quietPeriod,
        ...(overrides.continuity?.quietPeriod || {})
      },
      turnBoundary: {
        ...payload.continuity.turnBoundary,
        ...(overrides.continuity?.turnBoundary || {})
      }
    },
    issueContext: {
      ...payload.issueContext,
      ...(overrides.issueContext || {})
    }
  });
}

test('parseArgs resolves default output paths from repo root', () => {
  const parsed = parseArgs(['--repo-root', 'C:/repo']);
  assert.match(parsed.continuityPath, /continuity-telemetry\.json$/);
  assert.match(parsed.runtimeOutputPath, /operator-steering-event\.json$/);
  assert.match(parsed.handoffOutputPath, /operator-steering-event\.json$/);
});

test('buildOperatorSteeringEvent creates a funding-aware steering event for active-work continuity', () => {
  const root = createFixtureRoot('operator-steering-build');
  writeContinuity(root);
  writeJson(path.join(root, 'tests', 'results', '_agent', 'cost', 'invoice-turns', 'HQ1VJLMV-0027.json'), {
    invoiceTurnId: 'invoice-turn-2026-03-HQ1VJLMV-0027',
    policy: {
      fundingPurpose: 'operational',
      activationState: 'active'
    }
  });

  const result = buildOperatorSteeringEvent({
    repoRoot: root,
    continuityPath: path.join(root, 'tests', 'results', '_agent', 'runtime', 'continuity-telemetry.json'),
    runtimeOutputPath: path.join(root, 'tests', 'results', '_agent', 'runtime', 'operator-steering-event.json'),
    handoffOutputPath: path.join(root, 'tests', 'results', '_agent', 'handoff', 'operator-steering-event.json'),
    historyDir: path.join(root, 'tests', 'results', '_agent', 'runtime', 'operator-steering-events'),
    invoiceTurnDir: path.join(root, 'tests', 'results', '_agent', 'cost', 'invoice-turns'),
    steeringKind: 'operator-prompt-resume',
    triggerKind: 'continuity-failure'
  }, new Date('2026-03-21T23:11:00.000Z'));

  assert.equal(result.status, 'created');
  assert.equal(result.report.issueContext.issue, 1696);
  assert.equal(result.report.continuity.turnBoundary.operatorTurnEndWouldCreateIdleGap, true);
  assert.equal(result.report.fundingWindow.invoiceTurnId, 'invoice-turn-2026-03-HQ1VJLMV-0027');
  assert.equal(result.report.fundingWindow.activationState, 'active');
});

test('runOperatorSteeringEvent dedupes identical continuity resumes', () => {
  const root = createFixtureRoot('operator-steering-dedupe');
  writeContinuity(root);
  const options = {
    repoRoot: root,
    continuityPath: path.join(root, 'tests', 'results', '_agent', 'runtime', 'continuity-telemetry.json'),
    runtimeOutputPath: path.join(root, 'tests', 'results', '_agent', 'runtime', 'operator-steering-event.json'),
    handoffOutputPath: path.join(root, 'tests', 'results', '_agent', 'handoff', 'operator-steering-event.json'),
    historyDir: path.join(root, 'tests', 'results', '_agent', 'runtime', 'operator-steering-events'),
    invoiceTurnDir: path.join(root, 'tests', 'results', '_agent', 'cost', 'invoice-turns')
  };

  const first = runOperatorSteeringEvent(options, new Date('2026-03-21T23:12:00.000Z'));
  assert.equal(first.status, 'created');
  const second = runOperatorSteeringEvent(options, new Date('2026-03-21T23:13:00.000Z'));
  assert.equal(second.status, 'deduped');
});

test('runOperatorSteeringEvent returns no-event when continuity is safe-idle', () => {
  const root = createFixtureRoot('operator-steering-noop');
  writeContinuity(root, {
    status: 'maintained',
    issueContext: {
      mode: 'queue-empty',
      issue: null,
      reason: 'queue-empty'
    },
    continuity: {
      status: 'maintained',
      turnBoundary: {
        status: 'safe-idle',
        operatorTurnEndWouldCreateIdleGap: false,
        activeLaneIssue: null,
        wakeCondition: null,
        source: 'queue-empty',
        reason: 'standing-priority queue is explicitly empty'
      }
    }
  });

  const result = runOperatorSteeringEvent({
    repoRoot: root,
    continuityPath: path.join(root, 'tests', 'results', '_agent', 'runtime', 'continuity-telemetry.json'),
    runtimeOutputPath: path.join(root, 'tests', 'results', '_agent', 'runtime', 'operator-steering-event.json'),
    handoffOutputPath: path.join(root, 'tests', 'results', '_agent', 'handoff', 'operator-steering-event.json'),
    historyDir: path.join(root, 'tests', 'results', '_agent', 'runtime', 'operator-steering-events'),
    invoiceTurnDir: path.join(root, 'tests', 'results', '_agent', 'cost', 'invoice-turns')
  }, new Date('2026-03-21T23:14:00.000Z'));

  assert.equal(result.status, 'no-event');
  assert.equal(fs.existsSync(path.join(root, 'tests', 'results', '_agent', 'runtime', 'operator-steering-event.json')), false);
});

test('buildOperatorSteeringEvent falls back to sibling worktree invoice-turn receipts when the current lane has none', () => {
  const repoParent = fs.mkdtempSync(path.join(os.tmpdir(), 'operator-steering-sibling-'));
  const root = path.join(repoParent, 'compare-vi-cli-action.operator-steering-1718');
  const sibling = path.join(repoParent, 'compare-vi-cli-action.usage-calibration-1671');

  fs.mkdirSync(path.join(root, 'tests', 'results', '_agent', 'runtime'), { recursive: true });
  fs.mkdirSync(path.join(root, 'tests', 'results', '_agent', 'handoff'), { recursive: true });
  fs.mkdirSync(path.join(sibling, 'tests', 'results', '_agent', 'cost', 'invoice-turns'), { recursive: true });

  writeContinuity(root);
  writeJson(path.join(sibling, 'tests', 'results', '_agent', 'cost', 'invoice-turns', 'HQ1VJLMV-0027.local.json'), {
    invoiceTurnId: 'invoice-turn-2026-03-HQ1VJLMV-0027',
    policy: {
      fundingPurpose: 'operational',
      activationState: 'active'
    }
  });

  const result = buildOperatorSteeringEvent({
    repoRoot: root,
    continuityPath: path.join(root, 'tests', 'results', '_agent', 'runtime', 'continuity-telemetry.json'),
    runtimeOutputPath: path.join(root, 'tests', 'results', '_agent', 'runtime', 'operator-steering-event.json'),
    handoffOutputPath: path.join(root, 'tests', 'results', '_agent', 'handoff', 'operator-steering-event.json'),
    historyDir: path.join(root, 'tests', 'results', '_agent', 'runtime', 'operator-steering-events'),
    invoiceTurnDir: path.join(root, 'tests', 'results', '_agent', 'cost', 'invoice-turns')
  }, new Date('2026-03-21T23:17:00.000Z'));

  assert.equal(result.status, 'created');
  assert.equal(result.report.fundingWindow.status, 'resolved');
  assert.equal(result.report.fundingWindow.invoiceTurnId, 'invoice-turn-2026-03-HQ1VJLMV-0027');
  assert.match(result.report.fundingWindow.path, /usage-calibration-1671/i);
});

test('buildOperatorSteeringEvent prefers real local invoice-turn receipts over newer sample artifacts', () => {
  const repoParent = fs.mkdtempSync(path.join(os.tmpdir(), 'operator-steering-real-invoice-'));
  const root = path.join(repoParent, 'compare-vi-cli-action.operator-steering-1718');
  const sampleSibling = path.join(repoParent, 'compare-vi-cli-action.invoice-normalization-1660');
  const realSibling = path.join(repoParent, 'compare-vi-cli-action.usage-calibration-1671');

  fs.mkdirSync(path.join(root, 'tests', 'results', '_agent', 'runtime'), { recursive: true });
  fs.mkdirSync(path.join(root, 'tests', 'results', '_agent', 'handoff'), { recursive: true });
  fs.mkdirSync(path.join(sampleSibling, 'tests', 'results', '_agent', 'cost', 'invoice-turns'), { recursive: true });
  fs.mkdirSync(path.join(realSibling, 'tests', 'results', '_agent', 'cost', 'invoice-turns'), { recursive: true });

  writeContinuity(root);
  writeJson(path.join(sampleSibling, 'tests', 'results', '_agent', 'cost', 'invoice-turns', 'private-invoice-normalized-sample.json'), {
    invoiceTurnId: 'invoice-turn-2026-03-HQ1VJLMV-0027',
    policy: {
      fundingPurpose: 'operational',
      activationState: 'active'
    }
  });
  writeJson(path.join(realSibling, 'tests', 'results', '_agent', 'cost', 'invoice-turns', 'HQ1VJLMV-0027.local.json'), {
    invoiceTurnId: 'invoice-turn-2026-03-HQ1VJLMV-0027',
    policy: {
      fundingPurpose: 'operational',
      activationState: 'active'
    }
  });

  const result = buildOperatorSteeringEvent({
    repoRoot: root,
    continuityPath: path.join(root, 'tests', 'results', '_agent', 'runtime', 'continuity-telemetry.json'),
    runtimeOutputPath: path.join(root, 'tests', 'results', '_agent', 'runtime', 'operator-steering-event.json'),
    handoffOutputPath: path.join(root, 'tests', 'results', '_agent', 'handoff', 'operator-steering-event.json'),
    historyDir: path.join(root, 'tests', 'results', '_agent', 'runtime', 'operator-steering-events'),
    invoiceTurnDir: path.join(root, 'tests', 'results', '_agent', 'cost', 'invoice-turns')
  }, new Date('2026-03-21T23:18:00.000Z'));

  assert.equal(result.status, 'created');
  assert.match(result.report.fundingWindow.path, /HQ1VJLMV-0027\.local\.json$/i);
  assert.doesNotMatch(result.report.fundingWindow.path, /normalized-sample/i);
});

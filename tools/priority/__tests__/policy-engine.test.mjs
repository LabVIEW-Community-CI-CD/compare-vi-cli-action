#!/usr/bin/env node

import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {
  evaluateExactCheckNameGate,
  evaluateRoutingPolicy,
  normalizePolicy,
  parseArgs,
  runPolicyEngine
} from '../policy-engine.mjs';

function samplePolicy(overrides = {}) {
  return {
    schema: 'issue-routing-policy@v1',
    schemaVersion: '1.0.0',
    queueManagedBranches: ['develop', 'main'],
    defaultAction: {
      type: 'comment',
      priority: 'P2',
      labels: ['ci'],
      owner: null,
      titlePrefix: '[Ops]',
      reason: 'default'
    },
    rules: [
      {
        id: 'b-rule',
        order: 20,
        enabled: true,
        match: {
          sourceTypes: ['workflow-run'],
          incidentClasses: ['workflow-run-failure']
        },
        action: {
          type: 'open-issue',
          priority: 'P1',
          labels: ['ci'],
          owner: 'platform',
          titlePrefix: '[Workflow]',
          reason: 'workflow-failure'
        }
      },
      {
        id: 'a-rule',
        order: 10,
        enabled: true,
        match: {
          sourceTypes: ['required-check-drift'],
          incidentClasses: ['required-check-drift'],
          requiresQueueManagedBranch: true,
          requiresExactCheckNames: true
        },
        action: {
          type: 'open-issue',
          priority: 'P0',
          labels: ['governance'],
          owner: 'platform',
          titlePrefix: '[Policy]',
          reason: 'drift'
        }
      }
    ],
    ...overrides
  };
}

test('parseArgs enforces required event path and supports overrides', () => {
  const parsed = parseArgs([
    'node',
    'policy-engine.mjs',
    '--event',
    'event.json',
    '--policy',
    'policy.json',
    '--branch-policy',
    'branch-policy.json',
    '--report',
    'report.json',
    '--branch',
    'develop',
    '--dry-run'
  ]);

  assert.equal(parsed.eventPath, 'event.json');
  assert.equal(parsed.policyPath, 'policy.json');
  assert.equal(parsed.branchPolicyPath, 'branch-policy.json');
  assert.equal(parsed.reportPath, 'report.json');
  assert.equal(parsed.branchOverride, 'develop');
  assert.equal(parsed.dryRun, true);
});

test('normalizePolicy sorts rules deterministically by order then id', () => {
  const policy = normalizePolicy(samplePolicy());
  assert.deepEqual(
    policy.rules.map((rule) => rule.id),
    ['a-rule', 'b-rule']
  );
});

test('evaluateExactCheckNameGate requires exact check-name matches', () => {
  const pass = evaluateExactCheckNameGate({
    expectedChecks: ['lint', 'fixtures'],
    observedChecks: ['fixtures', 'lint']
  });
  assert.equal(pass.required, true);
  assert.equal(pass.exactMatch, true);

  const fail = evaluateExactCheckNameGate({
    expectedChecks: ['lint', 'fixtures'],
    observedChecks: ['lint', 'session-index']
  });
  assert.equal(fail.exactMatch, false);
  assert.deepEqual(fail.missing, ['fixtures']);
  assert.deepEqual(fail.extra, ['session-index']);
});

test('evaluateRoutingPolicy applies queue-managed and exact-check gates', () => {
  const policy = normalizePolicy(samplePolicy());
  const queueManaged = new Set(['develop', 'main']);
  const event = {
    sourceType: 'required-check-drift',
    incidentClass: 'required-check-drift',
    severity: 'high',
    repository: 'example/repo',
    branch: 'develop',
    sha: 'abc',
    signature: 'fail:2',
    fingerprint: 'fp',
    suggestedLabels: ['ci'],
    metadata: {
      expectedChecks: ['lint', 'fixtures'],
      observedChecks: ['lint', 'fixtures']
    }
  };
  const decision = evaluateRoutingPolicy({
    policy,
    event,
    queueManagedBranches: queueManaged,
    now: new Date('2026-03-06T21:20:00Z')
  });
  assert.equal(decision.selectedRuleId, 'a-rule');
  assert.equal(decision.selectedAction.priority, 'P0');
  assert.deepEqual(decision.selectedAction.labels, ['ci', 'governance']);

  const notExact = evaluateRoutingPolicy({
    policy,
    event: {
      ...event,
      metadata: {
        expectedChecks: ['lint', 'fixtures'],
        observedChecks: ['lint', 'session-index']
      }
    },
    queueManagedBranches: queueManaged,
    now: new Date('2026-03-06T21:20:00Z')
  });
  assert.equal(notExact.selectedRuleId, null);
  assert.equal(notExact.selectedAction.priority, 'P2');
});

test('runPolicyEngine writes deterministic decision report', async () => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'policy-engine-'));
  const policyPath = path.join(tmpDir, 'policy.json');
  const branchPolicyPath = path.join(tmpDir, 'branch-policy.json');
  const eventPath = path.join(tmpDir, 'event.json');
  const reportPath = path.join(tmpDir, 'report.json');

  fs.writeFileSync(policyPath, `${JSON.stringify(samplePolicy(), null, 2)}\n`, 'utf8');
  fs.writeFileSync(
    branchPolicyPath,
    `${JSON.stringify(
      {
        rulesets: {
          '1': {
            includes: ['refs/heads/develop'],
            merge_queue: { merge_method: 'SQUASH' }
          }
        }
      },
      null,
      2
    )}\n`,
    'utf8'
  );
  fs.writeFileSync(
    eventPath,
    `${JSON.stringify(
      {
        schema: 'incident-event@v1',
        sourceType: 'required-check-drift',
        incidentClass: 'required-check-drift',
        severity: 'high',
        branch: 'develop',
        sha: 'abc123',
        signature: 'fail:2',
        fingerprint: 'deadbeef',
        suggestedLabels: ['ci'],
        metadata: {
          expectedChecks: ['lint', 'fixtures'],
          observedChecks: ['fixtures', 'lint']
        }
      },
      null,
      2
    )}\n`,
    'utf8'
  );

  const result = await runPolicyEngine({
    argv: [
      'node',
      'policy-engine.mjs',
      '--event',
      eventPath,
      '--policy',
      policyPath,
      '--branch-policy',
      branchPolicyPath,
      '--report',
      reportPath
    ],
    now: new Date('2026-03-06T21:21:00Z'),
    repoRoot: tmpDir
  });

  assert.equal(result.exitCode, 0);
  assert.equal(result.report.status, 'pass');
  assert.equal(result.report.evaluation.selectedRuleId, 'a-rule');
  assert.equal(result.report.decision.priority, 'P0');
  assert.deepEqual(result.report.decision.labels, ['ci', 'governance']);

  const persisted = JSON.parse(fs.readFileSync(reportPath, 'utf8'));
  assert.equal(persisted.schema, 'priority/policy-decision-report@v1');
  assert.equal(persisted.checkNameGate.exactMatch, true);
});

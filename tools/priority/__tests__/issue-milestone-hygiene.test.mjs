#!/usr/bin/env node

import test from 'node:test';
import assert from 'node:assert/strict';
import path from 'node:path';
import {
  DEFAULT_POLICY_PATH,
  parseArgs,
  normalizePolicy,
  evaluateIssue,
  runMilestoneHygiene
} from '../check-issue-milestones.mjs';

function makeRunGhJson({ issues = [], milestones = [], createdMilestone = null, calls = [] } = {}) {
  return (args) => {
    calls.push(args);
    if (args[0] === 'issue' && args[1] === 'list') {
      return issues;
    }
    if (args[0] === 'api' && String(args[1]).includes('/milestones')) {
      if (args.includes('--method') && args.includes('POST')) {
        return createdMilestone ? [createdMilestone] : [];
      }
      return milestones;
    }
    throw new Error(`Unexpected gh json invocation: ${args.join(' ')}`);
  };
}

test('parseArgs uses repo from env and applies defaults', () => {
  const parsed = parseArgs([], { GITHUB_REPOSITORY: 'example/repo' });
  assert.equal(parsed.repo, 'example/repo');
  assert.equal(parsed.policyPath, DEFAULT_POLICY_PATH);
  assert.equal(parsed.state, 'open');
  assert.equal(parsed.limit, 200);
  assert.equal(parsed.applyDefaultMilestone, false);
  assert.equal(parsed.createDefaultMilestone, false);
  assert.equal(parsed.requireOpenMilestone, null);
  assert.equal(parsed.warnOnly, null);
});

test('normalizePolicy applies defaults and validates required settings', () => {
  const policy = normalizePolicy({});
  assert.deepEqual(policy.required.labels, ['standing-priority', 'program']);
  assert.equal(policy.required.titlePriorityPattern, String.raw`\[(P0|P1)\]`);
  assert.equal(policy.required.requireOpenMilestone, true);
  assert.equal(policy.defaultMilestone, null);
  assert.equal(policy.defaultMilestoneDueOn, null);
  assert.equal(policy.warnOnly, false);
  assert.equal(policy.createDefaultMilestone, false);
});

test('evaluateIssue marks missing and closed milestone violations', () => {
  const context = {
    requiredLabels: ['standing-priority', 'program'],
    titlePriorityPattern: String.raw`\[(P0|P1)\]`,
    requireOpenMilestone: true,
    milestonesByNumber: new Map([[7, { number: 7, title: 'Q1', state: 'closed' }]])
  };

  const missing = evaluateIssue(
    {
      number: 11,
      title: '[P1] missing',
      milestone: null,
      labels: [{ name: 'ci' }],
      url: 'https://example.test/issues/11'
    },
    context
  );
  assert.equal(missing.requiresMilestone, true);
  assert.equal(missing.isViolation, true);
  assert.equal(missing.reason, 'missing-milestone');

  const closed = evaluateIssue(
    {
      number: 12,
      title: '[P0] closed lane',
      milestone: { number: 7, title: 'Q1' },
      labels: [{ name: 'ci' }],
      url: 'https://example.test/issues/12'
    },
    context
  );
  assert.equal(closed.requiresMilestone, true);
  assert.equal(closed.isViolation, true);
  assert.equal(closed.reason, 'closed-milestone');
});

test('runMilestoneHygiene fails when required issues have no milestone and emits report flags', async () => {
  const writes = [];
  const ghCalls = [];
  const result = await runMilestoneHygiene({
    argv: ['--repo', 'example/repo'],
    loadPolicyFn: async () => ({
      path: path.join(process.cwd(), 'tools', 'policy', 'issue-milestone-hygiene.json'),
      required: {
        labels: ['standing-priority', 'program'],
        titlePriorityPattern: String.raw`\[(P0|P1)\]`,
        requireOpenMilestone: true
      },
      defaultMilestone: null,
      defaultMilestoneDueOn: null,
      warnOnly: false,
      createDefaultMilestone: false
    }),
    runGhJsonFn: makeRunGhJson({
      issues: [
        {
          number: 101,
          title: '[P1] missing milestone',
          milestone: null,
          labels: [{ name: 'ci' }],
          url: 'https://example.test/issues/101'
        }
      ],
      milestones: [{ number: 2, title: 'Program', state: 'open', dueOn: null }],
      calls: ghCalls
    }),
    writeJsonReportFn: async (reportPath, payload) => {
      writes.push({ reportPath, payload });
      return reportPath;
    }
  });

  assert.equal(result.exitCode, 1);
  assert.equal(result.report.flags.requireOpenMilestone, true);
  assert.equal(result.report.summary.remainingViolationCount, 1);
  assert.equal(result.report.summary.triggerCounts['title-priority'], 1);
  assert.equal(writes.length, 1);
  assert.equal(ghCalls.length >= 2, true);
});

test('runMilestoneHygiene assigns default milestone in apply mode', async () => {
  const edits = [];
  const result = await runMilestoneHygiene({
    argv: [
      '--repo',
      'example/repo',
      '--apply-default-milestone',
      '--default-milestone',
      'Backlog / Unscheduled'
    ],
    loadPolicyFn: async () => ({
      path: path.join(process.cwd(), 'tools', 'policy', 'issue-milestone-hygiene.json'),
      required: {
        labels: ['standing-priority', 'program'],
        titlePriorityPattern: String.raw`\[(P0|P1)\]`,
        requireOpenMilestone: true
      },
      defaultMilestone: null,
      defaultMilestoneDueOn: null,
      warnOnly: false,
      createDefaultMilestone: false
    }),
    runGhJsonFn: makeRunGhJson({
      issues: [
        {
          number: 111,
          title: '[P0] needs assignment',
          milestone: null,
          labels: [{ name: 'ci' }],
          url: 'https://example.test/issues/111'
        }
      ],
      milestones: [{ number: 12, title: 'Backlog / Unscheduled', state: 'open', dueOn: null }]
    }),
    runGhFn: (args) => {
      edits.push(args);
      return { status: 0, stdout: '', stderr: '' };
    },
    writeJsonReportFn: async (reportPath) => reportPath
  });

  assert.equal(result.exitCode, 0);
  assert.equal(result.report.summary.initialViolationCount, 1);
  assert.equal(result.report.summary.remainingViolationCount, 0);
  assert.equal(result.report.summary.assignedDefaultMilestoneCount, 1);
  assert.equal(result.report.milestones.createdDefaultMilestone, false);
  assert.equal(edits.length, 1);
  assert.deepEqual(edits[0], [
    'issue',
    'edit',
    '111',
    '--repo',
    'example/repo',
    '--milestone',
    'Backlog / Unscheduled'
  ]);
});

test('runMilestoneHygiene creates missing default milestone when requested', async () => {
  const ghCalls = [];
  const edits = [];
  const result = await runMilestoneHygiene({
    argv: [
      '--repo',
      'example/repo',
      '--apply-default-milestone',
      '--default-milestone',
      'Program Q2',
      '--default-milestone-due-on',
      '2026-06-30T00:00:00Z',
      '--create-default-milestone'
    ],
    loadPolicyFn: async () => ({
      path: path.join(process.cwd(), 'tools', 'policy', 'issue-milestone-hygiene.json'),
      required: {
        labels: ['standing-priority', 'program'],
        titlePriorityPattern: String.raw`\[(P0|P1)\]`,
        requireOpenMilestone: true
      },
      defaultMilestone: null,
      defaultMilestoneDueOn: null,
      warnOnly: false,
      createDefaultMilestone: false
    }),
    runGhJsonFn: makeRunGhJson({
      issues: [
        {
          number: 201,
          title: '[P1] needs milestone',
          milestone: null,
          labels: [{ name: 'program' }],
          url: 'https://example.test/issues/201'
        }
      ],
      milestones: [],
      createdMilestone: {
        number: 33,
        title: 'Program Q2',
        state: 'open',
        due_on: '2026-06-30T00:00:00Z'
      },
      calls: ghCalls
    }),
    runGhFn: (args) => {
      edits.push(args);
      return { status: 0, stdout: '', stderr: '' };
    },
    writeJsonReportFn: async (reportPath) => reportPath
  });

  assert.equal(result.exitCode, 0);
  assert.equal(result.report.milestones.createdDefaultMilestone, true);
  assert.equal(result.report.policy.defaultMilestoneDueOn, '2026-06-30T00:00:00Z');
  assert.equal(result.report.summary.assignedDefaultMilestoneCount, 1);
  assert.equal(ghCalls.some((args) => args.includes('--method') && args.includes('POST')), true);
  assert.equal(edits.length, 1);
});

test('runMilestoneHygiene rejects closed default milestone in strict mode', async () => {
  await assert.rejects(
    runMilestoneHygiene({
      argv: [
        '--repo',
        'example/repo',
        '--apply-default-milestone',
        '--default-milestone',
        'Program Closed'
      ],
      loadPolicyFn: async () => ({
        path: path.join(process.cwd(), 'tools', 'policy', 'issue-milestone-hygiene.json'),
        required: {
          labels: ['standing-priority', 'program'],
          titlePriorityPattern: String.raw`\[(P0|P1)\]`,
          requireOpenMilestone: true
        },
        defaultMilestone: null,
        defaultMilestoneDueOn: null,
        warnOnly: false,
        createDefaultMilestone: false
      }),
      runGhJsonFn: makeRunGhJson({
        issues: [],
        milestones: [{ number: 44, title: 'Program Closed', state: 'closed', dueOn: null }]
      })
    }),
    /closed/
  );
});

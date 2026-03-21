import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';

import {
  buildContinuityTelemetry,
  parseArgs,
  runContinuityTelemetry
} from '../continuity-telemetry.mjs';

const repoRoot = path.resolve(process.cwd());

function writeJson(filePath, payload) {
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
  fs.writeFileSync(filePath, `${JSON.stringify(payload, null, 2)}\n`, 'utf8');
}

function createRepoFixture(name) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), `${name}-`));
  fs.mkdirSync(path.join(root, '.git', 'agent-writer-leases'), { recursive: true });
  fs.mkdirSync(path.join(root, 'tests', 'results', '_agent', 'issue'), { recursive: true });
  fs.mkdirSync(path.join(root, 'tests', 'results', '_agent', 'handoff'), { recursive: true });
  fs.mkdirSync(path.join(root, 'tests', 'results', '_agent', 'runtime'), { recursive: true });
  fs.mkdirSync(path.join(root, 'tests', 'results', '_agent', 'sessions'), { recursive: true });
  return root;
}

test('parseArgs captures explicit continuity output paths', () => {
  const parsed = parseArgs([
    '--repo-root',
    'C:/repo',
    '--output',
    'tests/results/_agent/runtime/custom-continuity.json',
    '--handoff-output',
    'tests/results/_agent/handoff/custom-continuity.json',
    '--now',
    '2026-03-21T20:00:00.000Z'
  ]);

  assert.equal(parsed.repoRoot, path.resolve('C:/repo'));
  assert.match(parsed.runtimeOutputPath, /custom-continuity\.json$/);
  assert.match(parsed.handoffOutputPath, /custom-continuity\.json$/);
  assert.equal(parsed.now, '2026-03-21T20:00:00.000Z');
});

test('buildContinuityTelemetry treats a quiet period as covered when unattended signals stay fresh', () => {
  const fixtureRoot = createRepoFixture('continuity-maintained');
  const now = new Date('2026-03-21T20:00:00.000Z');

  writeJson(path.join(fixtureRoot, '.git', 'agent-writer-leases', 'workspace.json'), {
    schema: 'agent/writer-lease@v1',
    scope: 'workspace',
    leaseId: 'lease-1',
    owner: 'agent@host:default',
    acquiredAt: '2026-03-21T19:40:00.000Z',
    heartbeatAt: '2026-03-21T19:55:00.000Z'
  });
  writeJson(path.join(fixtureRoot, 'tests', 'results', '_agent', 'issue', 'router.json'), {
    schema: 'agent/priority-router@v1',
    issue: 1663,
    updatedAt: '2026-03-21T19:50:00.000Z',
    actions: []
  });
  writeJson(path.join(fixtureRoot, 'tests', 'results', '_agent', 'handoff', 'entrypoint-status.json'), {
    schema: 'agent-handoff/entrypoint-status-v1',
    generatedAt: '2026-03-21T19:54:00.000Z',
    handoffPath: 'AGENT_HANDOFF.txt',
    maxLines: 80,
    actualLineCount: 40,
    status: 'pass',
    checks: {
      primaryHeading: true,
      lineBudget: true,
      requiredHeadings: true,
      liveArtifactGuidance: true,
      stableEntrypointGuidance: true,
      noStatusLogGuidance: true,
      machineGeneratedArtifactGuidance: true,
      noDatedHistorySections: true
    },
    commands: {
      bootstrap: 'pwsh -File tools/priority/bootstrap.ps1',
      standingPriority: 'pwsh -File tools/Get-StandingPriority.ps1 -Plain',
      printHandoff: 'pwsh -File tools/Print-AgentHandoff.ps1',
      projectPortfolio: 'node tools/npm/run-script.mjs priority:project:portfolio:check',
      developSync: 'node tools/npm/run-script.mjs priority:develop:sync'
    },
    artifacts: {
      priorityCache: '.agent_priority_cache.json',
      router: 'tests/results/_agent/issue/router.json',
      noStandingPriority: 'tests/results/_agent/issue/no-standing-priority.json',
      dockerReviewLoopSummary: 'tests/results/_agent/verification/docker-review-loop-summary.json',
      continuitySummary: 'tests/results/_agent/handoff/continuity-summary.json',
      entrypointStatus: 'tests/results/_agent/handoff/entrypoint-status.json',
      handoffGlob: 'tests/results/_agent/handoff/*.json',
      sessionGlob: 'tests/results/_agent/sessions/*.json'
    },
    violations: []
  });
  writeJson(path.join(fixtureRoot, 'tests', 'results', '_agent', 'runtime', 'delivery-agent-state.json'), {
    schema: 'priority/delivery-agent-runtime-state@v1',
    generatedAt: '2026-03-21T19:53:00.000Z',
    status: 'running',
    activeLane: { issue: 1663 }
  });

  const { report } = buildContinuityTelemetry({ repoRoot: fixtureRoot }, now);
  assert.equal(report.status, 'maintained');
  assert.equal(report.issueContext.mode, 'issue');
  assert.equal(report.continuity.preservedWithoutPrompt, true);
  assert.equal(report.continuity.quietPeriod.operatorQuietPeriodTreatedAsPause, false);
  assert.equal(report.continuity.quietPeriod.status, 'covered');
});

test('buildContinuityTelemetry resolves writer leases from git-common-dir for linked worktrees', () => {
  const fixtureRoot = createRepoFixture('continuity-worktree');
  const now = new Date('2026-03-21T20:00:00.000Z');
  const commonGitDir = path.join(fixtureRoot, 'mock-common-dir');

  fs.rmSync(path.join(fixtureRoot, '.git', 'agent-writer-leases'), { recursive: true, force: true });
  fs.mkdirSync(path.join(commonGitDir, 'agent-writer-leases'), { recursive: true });

  writeJson(path.join(commonGitDir, 'agent-writer-leases', 'workspace.json'), {
    schema: 'agent/writer-lease@v1',
    scope: 'workspace',
    leaseId: 'lease-worktree',
    owner: 'agent@host:default',
    acquiredAt: '2026-03-21T19:40:00.000Z',
    heartbeatAt: '2026-03-21T19:58:00.000Z'
  });
  writeJson(path.join(fixtureRoot, 'tests', 'results', '_agent', 'issue', 'router.json'), {
    schema: 'agent/priority-router@v1',
    issue: 1663,
    updatedAt: '2026-03-21T19:59:00.000Z',
    actions: []
  });
  writeJson(path.join(fixtureRoot, 'tests', 'results', '_agent', 'runtime', 'observer-heartbeat.json'), {
    schema: 'priority/runtime-observer-heartbeat@v1',
    generatedAt: '2026-03-21T19:57:30.000Z',
    outcome: 'running'
  });

  const { report } = buildContinuityTelemetry({
    repoRoot: fixtureRoot,
    spawnSyncFn(command, args) {
      assert.equal(command, 'git');
      if (args[0] === 'rev-parse' && args[1] === '--show-toplevel') {
        return {
          status: 0,
          stdout: `${fixtureRoot}\n`,
          stderr: ''
        };
      }
      if (args[0] === 'rev-parse' && args[1] === '--git-dir') {
        return {
          status: 0,
          stdout: `${path.join(fixtureRoot, '.git')}\n`,
          stderr: ''
        };
      }
      assert.deepEqual(args, ['rev-parse', '--git-common-dir']);
      return {
        status: 0,
        stdout: `${commonGitDir}\n`,
        stderr: ''
      };
    }
  }, now);

  assert.equal(report.sources.writerLease.exists, true);
  assert.equal(report.sources.writerLease.path, path.join(commonGitDir, 'agent-writer-leases', 'workspace.json'));
  assert.equal(report.status, 'maintained');
});

test('buildContinuityTelemetry preserves queue-empty continuity without inventing an issue', () => {
  const fixtureRoot = createRepoFixture('continuity-queue-empty');
  const now = new Date('2026-03-21T20:00:00.000Z');

  writeJson(path.join(fixtureRoot, '.git', 'agent-writer-leases', 'workspace.json'), {
    schema: 'agent/writer-lease@v1',
    scope: 'workspace',
    leaseId: 'lease-2',
    owner: 'agent@host:default',
    acquiredAt: '2026-03-21T19:40:00.000Z',
    heartbeatAt: '2026-03-21T19:58:00.000Z'
  });
  writeJson(path.join(fixtureRoot, 'tests', 'results', '_agent', 'issue', 'no-standing-priority.json'), {
    schema: 'standing-priority/no-standing@v1',
    generatedAt: '2026-03-21T19:58:00.000Z',
    reason: 'queue-empty',
    openIssueCount: 0,
    message: 'Standing-priority queue is empty.'
  });
  writeJson(path.join(fixtureRoot, 'tests', 'results', '_agent', 'runtime', 'observer-heartbeat.json'), {
    schema: 'priority/runtime-observer-heartbeat@v1',
    generatedAt: '2026-03-21T19:57:30.000Z',
    outcome: 'idle'
  });

  const { report } = buildContinuityTelemetry({ repoRoot: fixtureRoot }, now);
  assert.equal(report.status, 'maintained');
  assert.equal(report.issueContext.mode, 'queue-empty');
  assert.equal(report.issueContext.issue, null);
  assert.equal(report.continuity.quietPeriod.operatorQuietPeriodTreatedAsPause, false);
});

test('buildContinuityTelemetry marks continuity stale when all unattended signals are old or missing', () => {
  const fixtureRoot = createRepoFixture('continuity-stale');
  const now = new Date('2026-03-21T20:00:00.000Z');

  writeJson(path.join(fixtureRoot, '.git', 'agent-writer-leases', 'workspace.json'), {
    schema: 'agent/writer-lease@v1',
    scope: 'workspace',
    leaseId: 'lease-3',
    owner: 'agent@host:default',
    acquiredAt: '2026-03-20T10:00:00.000Z',
    heartbeatAt: '2026-03-20T10:00:00.000Z'
  });

  const { report } = buildContinuityTelemetry({ repoRoot: fixtureRoot }, now);
  assert.equal(report.status, 'stale');
  assert.equal(report.issueContext.mode, 'missing');
  assert.equal(report.continuity.quietPeriod.operatorQuietPeriodTreatedAsPause, true);
  assert.equal(report.continuity.recommendation, 'run bootstrap and refresh handoff surfaces');
});

test('runContinuityTelemetry writes both runtime and handoff continuity receipts', () => {
  const fixtureRoot = createRepoFixture('continuity-write');
  writeJson(path.join(fixtureRoot, '.git', 'agent-writer-leases', 'workspace.json'), {
    schema: 'agent/writer-lease@v1',
    scope: 'workspace',
    leaseId: 'lease-4',
    owner: 'agent@host:default',
    acquiredAt: '2026-03-21T19:40:00.000Z',
    heartbeatAt: '2026-03-21T19:58:00.000Z'
  });
  writeJson(path.join(fixtureRoot, 'tests', 'results', '_agent', 'issue', 'no-standing-priority.json'), {
    schema: 'standing-priority/no-standing@v1',
    generatedAt: '2026-03-21T19:58:00.000Z',
    reason: 'queue-empty',
    openIssueCount: 0,
    message: 'Standing-priority queue is empty.'
  });

  const runtimeOutputPath = path.join(fixtureRoot, 'tests', 'results', '_agent', 'runtime', 'continuity-telemetry.json');
  const handoffOutputPath = path.join(fixtureRoot, 'tests', 'results', '_agent', 'handoff', 'continuity-summary.json');

  runContinuityTelemetry({
    repoRoot: fixtureRoot,
    runtimeOutputPath,
    handoffOutputPath
  }, new Date('2026-03-21T20:00:00.000Z'));

  assert.equal(fs.existsSync(runtimeOutputPath), true);
  assert.equal(fs.existsSync(handoffOutputPath), true);
});

test('continuity telemetry CLI writes the default runtime and handoff reports', () => {
  const fixtureRoot = createRepoFixture('continuity-cli');
  writeJson(path.join(fixtureRoot, '.git', 'agent-writer-leases', 'workspace.json'), {
    schema: 'agent/writer-lease@v1',
    scope: 'workspace',
    leaseId: 'lease-5',
    owner: 'agent@host:default',
    acquiredAt: '2026-03-21T19:40:00.000Z',
    heartbeatAt: '2026-03-21T19:58:00.000Z'
  });
  writeJson(path.join(fixtureRoot, 'tests', 'results', '_agent', 'issue', 'no-standing-priority.json'), {
    schema: 'standing-priority/no-standing@v1',
    generatedAt: '2026-03-21T19:58:00.000Z',
    reason: 'queue-empty',
    openIssueCount: 0,
    message: 'Standing-priority queue is empty.'
  });
  writeJson(path.join(fixtureRoot, 'tests', 'results', '_agent', 'runtime', 'observer-heartbeat.json'), {
    schema: 'priority/runtime-observer-heartbeat@v1',
    generatedAt: '2026-03-21T19:57:30.000Z',
    outcome: 'idle'
  });

  const result = spawnSync(
    process.execPath,
    [
      path.join(repoRoot, 'tools', 'priority', 'continuity-telemetry.mjs'),
      '--repo-root',
      fixtureRoot,
      '--now',
      '2026-03-21T20:00:00.000Z'
    ],
    {
      cwd: repoRoot,
      encoding: 'utf8'
    }
  );

  assert.equal(result.status, 0, result.stderr);
  assert.match(result.stdout, /\[continuity\] status=maintained/);
  assert.equal(fs.existsSync(path.join(fixtureRoot, 'tests', 'results', '_agent', 'runtime', 'continuity-telemetry.json')), true);
  assert.equal(fs.existsSync(path.join(fixtureRoot, 'tests', 'results', '_agent', 'handoff', 'continuity-summary.json')), true);
});

#!/usr/bin/env node

import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { applyAutonomyPolicy, deriveEscalations, determinePhase, parseCsv, parseRequirementNumber, rankProofRegressions, rankRequirementGaps, runLiveHistoryCandidateProof, runWindowsWorkflowReplayProof, selectNextStep } from '../vi-history-local-ci.mjs';

test('parseRequirementNumber extracts numeric VI History local-proof ids', () => {
  assert.equal(parseRequirementNumber('REQ-VHLP-001'), 1);
  assert.equal(parseRequirementNumber('REQ-VHLP-006'), 6);
});

test('determinePhase groups VI History requirements into foundation and autonomy', () => {
  assert.equal(determinePhase(1), 'foundation');
  assert.equal(determinePhase(4), 'foundation');
  assert.equal(determinePhase(5), 'autonomy');
});

test('parseCsv handles quoted VI History RTM rows', () => {
  const rows = parseCsv([
    'ReqID,Requirement,Source,Priority,TestID,TestArtifact,CodeRef,Status',
    'REQ-VHLP-002,"Local refinement profiles remain stable, including windows-mirror-proof",docs/requirements.md,High,TEST-VHLP-002,"Planned local profile coverage",tools/Invoke-VIHistoryLocalRefinement.ps1,Gap'
  ].join('\n'));

  assert.equal(rows.length, 1);
  assert.equal(rows[0].ReqID, 'REQ-VHLP-002');
  assert.match(rows[0].Requirement, /windows-mirror-proof/);
});

test('rankRequirementGaps prefers earliest high-priority VI History local gaps', () => {
  const ranked = rankRequirementGaps([
    {
      ReqID: 'REQ-VHLP-006',
      Requirement: 'Escalation packet exists for shared Windows surface.',
      Source: 'docs/requirements.md',
      Priority: 'High',
      TestID: 'TEST-VHLP-006',
      TestArtifact: 'Planned escalation coverage',
      CodeRef: 'tools/priority/vi-history-local-ci.mjs',
      Status: 'Gap'
    },
    {
      ReqID: 'REQ-VHLP-001',
      Requirement: 'Windows workflow replay lane exists.',
      Source: 'docs/requirements.md',
      Priority: 'High',
      TestID: 'TEST-VHLP-001',
      TestArtifact: 'Planned replay coverage',
      CodeRef: 'tools/priority/windows-workflow-replay-lane.mjs',
      Status: 'Gap'
    }
  ]);

  assert.equal(ranked[0].req_id, 'REQ-VHLP-001');
  assert.equal(ranked[0].phase, 'foundation');
});

test('applyAutonomyPolicy prioritizes active VI History worktree matches', () => {
  const ranked = rankRequirementGaps([
    {
      ReqID: 'REQ-VHLP-002',
      Requirement: 'Local refinement profiles remain stable.',
      Source: 'docs/requirements.md',
      Priority: 'High',
      TestID: 'TEST-VHLP-002',
      TestArtifact: 'Planned local profile coverage',
      CodeRef: 'tools/Invoke-VIHistoryLocalRefinement.ps1',
      Status: 'Gap'
    }
  ]);
  const policy = JSON.parse(fs.readFileSync(path.join(process.cwd(), 'tools/priority/vi-history-local-proof-autonomy-policy.json'), 'utf8'));
  const guided = applyAutonomyPolicy(ranked, policy, ['tools/Invoke-VIHistoryLocalRefinement.ps1']);

  assert.equal(guided[0].active_now, true);
  assert.equal(guided[0].mode, 'local-first');
});

test('rankProofRegressions reopens implemented VI History requirements when proof checks fail', () => {
  const regressions = rankProofRegressions([
    {
      id: 'windows-workflow-replay',
      owner_requirement: 'REQ-VHLP-001',
      status: 'fail',
      blocking: true,
      summary: 'Windows workflow replay lane failed.'
    }
  ], [
    {
      ReqID: 'REQ-VHLP-001',
      Requirement: 'Windows workflow replay lane exists.',
      Source: 'docs/requirements.md',
      Priority: 'High',
      TestID: 'TEST-VHLP-001',
      TestArtifact: 'Replay lane proof',
      CodeRef: 'tools/priority/windows-workflow-replay-lane.mjs',
      Status: 'Implemented'
    }
  ]);

  assert.equal(regressions.length, 1);
  assert.equal(regressions[0].status, 'Regression');
  assert.equal(regressions[0].proof_check_id, 'windows-workflow-replay');
});

test('deriveEscalations emits a shared Windows-surface escalation for VI History', () => {
  const escalations = deriveEscalations([
    {
      id: 'windows-workflow-replay',
      owner_requirement: 'REQ-VHLP-001',
      status: 'advisory',
      blocking: false,
      summary: 'VI History Windows workflow replay is unavailable from the current host.',
      current_surface_status: 'unavailable',
      current_host_platform: 'Unix',
      receipt_path: 'tests/results/docker-tools-parity/workflow-replay/vi-history-scenarios-windows-receipt.json',
      recommended_commands: [
        'npm run docker:ni:windows:bootstrap',
        'npm run compare:docker:ni:windows:probe',
        'npm run priority:workflow:replay:windows:vi-history'
      ]
    }
  ]);

  assert.equal(escalations.length, 1);
  assert.equal(escalations[0].governing_requirement, 'REQ-VHLP-006');
  assert.equal(escalations[0].blocked_requirement, 'REQ-VHLP-001');
  assert.equal(escalations[0].required_surface, 'windows-docker-desktop-ni-image');
});

test('deriveEscalations emits an explicit Windows workflow replay next step when the shared surface is already ready', () => {
  const escalations = deriveEscalations([
    {
      id: 'windows-workflow-replay',
      owner_requirement: 'REQ-VHLP-001',
      status: 'advisory',
      blocking: false,
      summary: 'The governed VI History Windows workflow replay lane is ready and must be invoked explicitly as the next live-proof step.',
      current_surface_status: 'ready-for-explicit-replay',
      current_host_platform: 'Windows',
      receipt_path: 'tests/results/docker-tools-parity/workflow-replay/vi-history-scenarios-windows-receipt.json',
      reason: 'Local VI History CI keeps live Windows workflow replay as an explicit next step instead of running it implicitly during packet selection.',
      recommended_commands: [
        'npm run priority:workflow:replay:windows:vi-history'
      ]
    }
  ]);

  assert.equal(escalations.length, 1);
  assert.equal(escalations[0].governing_requirement, 'REQ-VHLP-010');
  assert.equal(escalations[0].blocked_requirement, 'REQ-VHLP-001');
  assert.equal(escalations[0].required_surface, 'vi-history-windows-workflow-replay');
});

test('deriveEscalations emits a clone-backed live-history escalation for VI History', () => {
  const escalations = deriveEscalations([
    {
      id: 'live-history-candidate',
      owner_requirement: 'REQ-VHLP-009',
      status: 'advisory',
      blocking: false,
      summary: 'The governed clone-backed VI History candidate is not cloned locally yet.',
      current_surface_status: 'missing-clone',
      current_host_platform: 'Unix',
      receipt_path: 'tests/results/_agent/vi-history-local-proof/local-ci/live-candidate/vi-history-live-candidate-readiness.json',
      reason: 'No local clone was found.',
      recommended_commands: [
        'git clone https://github.com/ni/labview-icon-editor.git /tmp/labview-icon-editor'
      ]
    }
  ]);

  assert.equal(escalations.length, 1);
  assert.equal(escalations[0].governing_requirement, 'REQ-VHLP-009');
  assert.equal(escalations[0].blocked_requirement, 'REQ-VHLP-008');
  assert.equal(escalations[0].required_surface, 'clone-backed-live-history-candidate');
});

test('runLiveHistoryCandidateProof validates a clone-backed target with real git history', async () => {
  const tempRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'vi-history-candidate-'));
  const repoDir = path.join(tempRoot, 'repo');
  const resultsDir = path.join(tempRoot, 'results');
  const candidatePath = path.join(tempRoot, 'candidate.json');
  const targetPath = path.join(repoDir, 'Tooling', 'deployment', 'VIP_Pre-Uninstall Custom Action.vi');

  fs.mkdirSync(path.dirname(targetPath), { recursive: true });
  spawnSync('git', ['init', '-b', 'develop', repoDir], { encoding: 'utf8' });
  fs.writeFileSync(targetPath, 'v1', 'utf8');
  spawnSync('git', ['-C', repoDir, 'add', '.'], { encoding: 'utf8' });
  spawnSync('git', ['-C', repoDir, '-c', 'user.name=Test', '-c', 'user.email=test@example.com', 'commit', '-m', 'initial'], { encoding: 'utf8' });
  fs.writeFileSync(targetPath, 'v2', 'utf8');
  spawnSync('git', ['-C', repoDir, 'add', '.'], { encoding: 'utf8' });
  spawnSync('git', ['-C', repoDir, '-c', 'user.name=Test', '-c', 'user.email=test@example.com', 'commit', '-m', 'second'], { encoding: 'utf8' });

  fs.writeFileSync(candidatePath, JSON.stringify({
    $schema: '../../docs/schemas/vi-history-live-candidate-v1.schema.json',
    schemaVersion: '1.0.0',
    id: 'test-live-candidate',
    repoSlug: 'example/repo',
    repoUrl: 'https://github.com/example/repo',
    defaultBranch: 'develop',
    cloneRootEnvVar: 'COMPAREVI_VI_HISTORY_CANDIDATE_ROOT',
    preferredLocalCloneRoots: [repoDir],
    targetViPath: 'Tooling/deployment/VIP_Pre-Uninstall Custom Action.vi',
    historyExpectation: { minCommits: 2 },
    iterationRationale: 'test'
  }, null, 2), 'utf8');

  const check = await runLiveHistoryCandidateProof(process.cwd(), resultsDir, path.relative(process.cwd(), candidatePath));

  assert.equal(check.status, 'pass');
  assert.equal(check.id, 'live-history-candidate');
  assert.match(check.summary, /ready for local iteration/i);
});

test('runWindowsWorkflowReplayProof consumes an existing passing replay receipt instead of re-requesting replay', async () => {
  const tempRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'vi-history-replay-pass-'));
  const receiptPath = path.join(tempRoot, 'tests', 'results', 'docker-tools-parity', 'workflow-replay', 'vi-history-scenarios-windows-receipt.json');
  fs.mkdirSync(path.dirname(receiptPath), { recursive: true });
  fs.writeFileSync(receiptPath, JSON.stringify({
    schema: 'windows-workflow-replay-lane@v1',
    schemaVersion: '1.0.0',
    replay: { mode: 'vi-history-scenarios-windows' },
    result: { status: 'passed', errorMessage: null },
  }, null, 2), 'utf8');

  const check = await runWindowsWorkflowReplayProof(tempRoot, path.join(tempRoot, 'results'), {
    runSharedWindowsSurfaceProofFn: async () => ({
      status: 'pass',
      blocking: false,
      current_surface_status: 'ready',
      current_host_platform: 'Windows',
      coordinator_host_platform: 'Unix',
      bridge_mode: 'wsl-windows',
      receipt_path: 'tests/results/_agent/windows-docker-shared-surface/local-ci/windows-surface/pester-windows-container-surface.json',
      reason: 'ready',
    }),
  });

  assert.equal(check.status, 'pass');
  assert.equal(check.current_surface_status, 'passed');
  assert.match(check.summary, /already passed/i);
});

test('selectNextStep prefers requirements before VI History escalations', () => {
  const requirement = {
    req_id: 'REQ-VHLP-002',
    priority: 'High',
    status: 'Gap',
    phase: 'foundation',
    score: 1234,
    why_now: 'Need refinement profile coverage.',
    requirement: 'Profiles stay stable.',
    test_id: 'TEST-VHLP-002',
    code_refs: ['tools/Invoke-VIHistoryLocalRefinement.ps1'],
    suggested_loop: ['Add local profile coverage.']
  };
  const escalation = { type: 'escalation', escalation_id: 'windows-docker-desktop-ni-image' };

  assert.equal(selectNextStep(requirement, [escalation]).type, 'requirement');
  assert.equal(selectNextStep(null, [escalation]).type, 'escalation');
});

test('VI History local CI uses a run-scoped audit bundle root', () => {
  const source = fs.readFileSync(path.join(process.cwd(), 'tools/priority/vi-history-local-ci.mjs'), 'utf8');

  assert.match(source, /createRunScopedBundleRoot/);
  assert.match(source, /surface-bundle/);
  assert.match(source, /run-\$\{Date\.now\(\)\}-\$\{process\.pid\}/);
});

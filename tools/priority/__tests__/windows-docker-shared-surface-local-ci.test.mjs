#!/usr/bin/env node

import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';

import { applyAutonomyPolicy, deriveEscalations, determinePhase, parseCsv, parseRequirementNumber, rankProofRegressions, rankRequirementGaps, runPathHygieneProof, selectNextStep } from '../windows-docker-shared-surface-local-ci.mjs';

test('parseRequirementNumber extracts numeric shared-surface ids', () => {
  assert.equal(parseRequirementNumber('REQ-WDSS-001'), 1);
  assert.equal(parseRequirementNumber('REQ-WDSS-006'), 6);
});

test('determinePhase groups shared-surface requirements into foundation and autonomy', () => {
  assert.equal(determinePhase(1), 'foundation');
  assert.equal(determinePhase(3), 'foundation');
  assert.equal(determinePhase(4), 'autonomy');
  assert.equal(determinePhase(7), 'autonomy');
});

test('parseCsv handles quoted shared-surface RTM rows', () => {
  const rows = parseCsv([
    'ReqID,Requirement,Source,Priority,TestID,TestArtifact,CodeRef,Status',
    'REQ-WDSS-003,"Shared surface detects OneDrive-managed roots",docs/requirements.md,High,TEST-WDSS-003,"Planned path-hygiene coverage",tools/priority/windows-docker-shared-surface-local-ci.mjs,Gap'
  ].join('\n'));

  assert.equal(rows.length, 1);
  assert.equal(rows[0].ReqID, 'REQ-WDSS-003');
  assert.match(rows[0].Requirement, /OneDrive-managed roots/);
});

test('rankRequirementGaps prefers earliest high-priority shared-surface gaps', () => {
  const ranked = rankRequirementGaps([
    {
      ReqID: 'REQ-WDSS-005',
      Requirement: 'Escalation packet exists for shared Windows surface.',
      Source: 'docs/requirements.md',
      Priority: 'High',
      TestID: 'TEST-WDSS-005',
      TestArtifact: 'Planned escalation coverage',
      CodeRef: 'tools/priority/windows-docker-shared-surface-local-ci.mjs',
      Status: 'Gap'
    },
    {
      ReqID: 'REQ-WDSS-001',
      Requirement: 'Shared-surface readiness probe exists.',
      Source: 'docs/requirements.md',
      Priority: 'High',
      TestID: 'TEST-WDSS-001',
      TestArtifact: 'Planned probe coverage',
      CodeRef: 'tools/Invoke-PesterWindowsContainerSurfaceProbe.ps1',
      Status: 'Gap'
    }
  ]);

  assert.equal(ranked[0].req_id, 'REQ-WDSS-001');
  assert.equal(ranked[0].phase, 'foundation');
});

test('applyAutonomyPolicy prioritizes active shared-surface worktree matches', () => {
  const ranked = rankRequirementGaps([
    {
      ReqID: 'REQ-WDSS-003',
      Requirement: 'Shared surface detects OneDrive-managed roots.',
      Source: 'docs/requirements.md',
      Priority: 'High',
      TestID: 'TEST-WDSS-003',
      TestArtifact: 'Planned path-hygiene coverage',
      CodeRef: 'tools/priority/windows-docker-shared-surface-local-ci.mjs',
      Status: 'Gap'
    }
  ]);
  const policy = JSON.parse(fs.readFileSync(path.join(process.cwd(), 'tools/priority/windows-docker-shared-surface-autonomy-policy.json'), 'utf8'));
  const guided = applyAutonomyPolicy(ranked, policy, ['tools/priority/windows-docker-shared-surface-local-ci.mjs']);

  assert.equal(guided[0].active_now, true);
  assert.equal(guided[0].mode, 'local-first');
});

test('rankProofRegressions reopens implemented shared-surface requirements when proof checks fail', () => {
  const regressions = rankProofRegressions([
    {
      id: 'windows-surface',
      owner_requirement: 'REQ-WDSS-001',
      status: 'fail',
      blocking: true,
      summary: 'Shared Windows surface probe failed.'
    }
  ], [
    {
      ReqID: 'REQ-WDSS-001',
      Requirement: 'Shared-surface readiness probe exists.',
      Source: 'docs/requirements.md',
      Priority: 'High',
      TestID: 'TEST-WDSS-001',
      TestArtifact: 'Probe proof',
      CodeRef: 'tools/Invoke-PesterWindowsContainerSurfaceProbe.ps1',
      Status: 'Implemented'
    }
  ]);

  assert.equal(regressions.length, 1);
  assert.equal(regressions[0].status, 'Regression');
  assert.equal(regressions[0].proof_check_id, 'windows-surface');
});

test('deriveEscalations emits a path-hygiene relocation escalation for shared Windows surface', () => {
  const escalations = deriveEscalations([
    {
      id: 'path-hygiene',
      owner_requirement: 'REQ-WDSS-003',
      status: 'advisory',
      blocking: false,
      summary: 'The shared Windows surface is currently rooted in a synchronized path.',
      current_surface_status: 'unsafe-synced-root',
      current_host_platform: 'Windows',
      receipt_path: 'tests/results/_agent/windows-docker-shared-surface/local-ci/path-hygiene/windows-docker-shared-surface-path-hygiene.json',
      reason: 'OneDrive-like managed roots can mutate artifacts during live proof.',
      recommended_commands: ['Move the repo to a safe local root.']
    }
  ]);

  assert.equal(escalations.length, 1);
  assert.equal(escalations[0].governing_requirement, 'REQ-WDSS-003');
  assert.equal(escalations[0].required_surface, 'local-safe-root');
});

test('deriveEscalations emits a shared Windows-surface escalation when host is unavailable', () => {
  const escalations = deriveEscalations([
    {
      id: 'windows-surface',
      owner_requirement: 'REQ-WDSS-001',
      status: 'advisory',
      blocking: false,
      summary: 'The shared Windows surface is unavailable from the current host.',
      current_surface_status: 'not-windows-host',
      current_host_platform: 'Unix',
      receipt_path: 'tests/results/_agent/windows-docker-shared-surface/local-ci/windows-surface/pester-windows-container-surface.json',
      reason: 'Current host is not Windows.',
      recommended_commands: ['npm run docker:ni:windows:bootstrap']
    }
  ]);

  assert.equal(escalations.length, 1);
  assert.equal(escalations[0].governing_requirement, 'REQ-WDSS-005');
  assert.equal(escalations[0].required_surface, 'windows-docker-desktop-ni-image');
});

test('deriveEscalations keeps bridge-unavailable shared-surface advisories on the Windows surface escalation', () => {
  const escalations = deriveEscalations([
    {
      id: 'windows-host-preflight',
      owner_requirement: 'REQ-WDSS-002',
      status: 'advisory',
      blocking: false,
      summary: 'Deterministic Windows host preflight is unavailable.',
      current_surface_status: 'windows-host-bridge-unavailable',
      current_host_platform: 'Unix',
      reason: 'No reachable Windows host bridge is available.',
      recommended_commands: ['npm run docker:ni:windows:bootstrap']
    }
  ]);

  assert.equal(escalations.length, 1);
  assert.equal(escalations[0].governing_requirement, 'REQ-WDSS-005');
  assert.equal(escalations[0].required_surface, 'windows-docker-desktop-ni-image');
});

test('runPathHygieneProof detects OneDrive-like roots', async () => {
  const riskyRoot = path.join(process.cwd(), 'tests', 'results', '_agent', 'OneDrive - Contoso', 'windows-shared-surface');
  const proof = await runPathHygieneProof(riskyRoot, path.join(riskyRoot, 'results'));

  assert.equal(proof.status, 'advisory');
  assert.equal(proof.id, 'path-hygiene');
  assert.match(proof.summary, /synchronized or externally managed path/i);
});

test('selectNextStep prefers a requirement before a shared-surface escalation', () => {
  const requirement = {
    type: 'requirement',
    req_id: 'REQ-WDSS-003',
    priority: 'High',
    status: 'Gap',
    phase: 'foundation',
    score: 1234,
    why_now: 'Need path hygiene coverage.',
    requirement: 'Shared surface stays off synced roots.',
    test_id: 'TEST-WDSS-003',
    code_refs: ['tools/priority/windows-docker-shared-surface-local-ci.mjs'],
    suggested_loop: ['Add path hygiene coverage.']
  };
  const escalation = { type: 'escalation', required_surface: 'windows-docker-desktop-ni-image' };

  assert.equal(selectNextStep(requirement, [escalation]).type, 'requirement');
  assert.equal(selectNextStep(null, [escalation]).type, 'escalation');
});

test('Windows shared-surface local CI uses a run-scoped audit bundle root', () => {
  const source = fs.readFileSync(path.join(process.cwd(), 'tools/priority/windows-docker-shared-surface-local-ci.mjs'), 'utf8');

  assert.match(source, /createRunScopedBundleRoot/);
  assert.match(source, /surface-bundle/);
  assert.match(source, /run-\$\{Date\.now\(\)\}-\$\{process\.pid\}/);
});

#!/usr/bin/env node

import test from 'node:test';
import assert from 'node:assert/strict';
import path from 'node:path';
import { readFileSync } from 'node:fs';

import { buildPostLocalPromotionEscalation, buildRequirementCandidate, mergeSharedSurfaceEscalations, rankProgramRequirements, selectProgramNextStep } from '../comparevi-local-program-ci.mjs';

const repoRoot = process.cwd();

function readRepoFile(relativePath) {
  return readFileSync(path.join(repoRoot, relativePath), 'utf8');
}

test('rankProgramRequirements prefers active requirement work over later passive packet work', () => {
  const ranked = rankProgramRequirements([
    buildRequirementCandidate(
      { id: 'vi-history-local-proof', label: 'VI History Local Proof' },
      'tests/results/_agent/vi-history-local-proof/local-ci/vi-history-local-ci-report.json',
      'tests/results/_agent/vi-history-local-proof/local-ci/vi-history-local-next-step.json',
      {
        req_id: 'REQ-VHLP-002',
        priority: 'High',
        status: 'Gap',
        phase: 'foundation',
        score: 1200,
        why_now: 'VI History refinement profile work remains.',
        requirement: 'Profiles stay stable.',
        test_id: 'TEST-VHLP-002',
        code_refs: ['tools/Invoke-VIHistoryLocalRefinement.ps1'],
        suggested_loop: ['Run the VI History refinement surface.'],
        active_now: false
      }
    ),
    buildRequirementCandidate(
      { id: 'pester-service-model', label: 'Pester Service Model' },
      'tests/results/_agent/pester-service-model/local-ci/pester-service-model-local-ci-report.json',
      'tests/results/_agent/pester-service-model/local-ci/pester-service-model-next-step.json',
      {
        req_id: 'REQ-PSM-015',
        priority: 'High',
        status: 'Regression',
        phase: 'execution-governance',
        score: 1100,
        why_now: 'Execution regression requires attention.',
        requirement: 'Dispatch side effects stay separated.',
        test_id: 'TEST-PSM-015',
        code_refs: ['Invoke-PesterTests.ps1'],
        suggested_loop: ['Fix the execution split.'],
        active_now: true
      }
    )
  ]);

  assert.equal(ranked[0].packet_id, 'pester-service-model');
  assert.equal(ranked[0].req_id, 'REQ-PSM-015');
});

test('mergeSharedSurfaceEscalations collapses packet escalations into one Windows-surface handoff', () => {
  const merged = mergeSharedSurfaceEscalations([
    {
      packet_id: 'pester-service-model',
      packet_label: 'Pester Service Model',
      source_next_step_path: 'tests/results/_agent/pester-service-model/local-ci/pester-service-model-next-step.json',
      escalation_id: 'windows-container-live-proof',
      governing_requirement: 'REQ-PSM-027',
      blocked_requirement: 'REQ-PSM-025',
      proof_check_id: 'windows-container-surface',
      status: 'required',
      mode: 'escalate',
      why_now: 'The next truthful Pester proof surface is unavailable.',
      reason: 'Current host is not Windows, so the Docker Desktop + NI Windows image proof surface cannot be exercised here.',
      required_surface: 'windows-docker-desktop-ni-image',
      current_surface_status: 'not-windows-host',
      current_host_platform: 'Unix',
      receipt_path: 'tests/results/_agent/pester-service-model/local-ci/windows-container-surface/pester-windows-container-surface.json',
      suggested_loop: ['Move to Windows.', 'Probe the shared surface.'],
      recommended_commands: ['npm run docker:ni:windows:bootstrap', 'npm run compare:docker:ni:windows:probe'],
      stop_conditions: ['Stop when the probe reports ready.']
    },
    {
      packet_id: 'vi-history-local-proof',
      packet_label: 'VI History Local Proof',
      source_next_step_path: 'tests/results/_agent/vi-history-local-proof/local-ci/vi-history-local-next-step.json',
      escalation_id: 'windows-docker-desktop-ni-image',
      governing_requirement: 'REQ-VHLP-006',
      blocked_requirement: 'REQ-VHLP-001',
      proof_check_id: 'windows-workflow-replay',
      status: 'required',
      mode: 'escalate',
      why_now: 'The next truthful VI History proof surface is unavailable.',
      reason: 'Current host is not Windows, so the VI History Windows workflow replay lane cannot be exercised here.',
      required_surface: 'windows-docker-desktop-ni-image',
      current_surface_status: 'not-windows-host',
      current_host_platform: 'Unix',
      receipt_path: 'tests/results/_agent/vi-history-local-proof/local-ci/windows-surface/vi-history-windows-surface.json',
      suggested_loop: ['Move to Windows.', 'Run the VI History replay lane.'],
      recommended_commands: ['npm run docker:ni:windows:bootstrap', 'npm run compare:docker:ni:windows:probe', 'npm run priority:workflow:replay:windows:vi-history'],
      stop_conditions: ['Stop when the replay lane passes.']
    },
    {
      packet_id: 'windows-docker-shared-surface',
      packet_label: 'Windows Docker Shared Surface',
      source_next_step_path: 'tests/results/_agent/windows-docker-shared-surface/local-ci/windows-docker-shared-surface-next-step.json',
      escalation_id: 'windows-docker-desktop-ni-image',
      governing_requirement: 'REQ-WDSS-005',
      blocked_requirement: 'REQ-WDSS-001',
      proof_check_id: 'windows-surface',
      status: 'required',
      mode: 'escalate',
      why_now: 'The shared Windows surface itself is unavailable from the current host.',
      reason: 'Current host is not Windows, so the shared Windows Docker Desktop + NI image surface cannot be exercised here.',
      required_surface: 'windows-docker-desktop-ni-image',
      current_surface_status: 'not-windows-host',
      current_host_platform: 'Unix',
      receipt_path: 'tests/results/_agent/windows-docker-shared-surface/local-ci/windows-surface/pester-windows-container-surface.json',
      suggested_loop: ['Move to Windows.', 'Probe the shared Windows surface.'],
      recommended_commands: ['npm run docker:ni:windows:bootstrap', 'npm run compare:docker:ni:windows:probe'],
      stop_conditions: ['Stop when the shared surface probe reaches ready.']
    }
  ]);

  assert.equal(merged.length, 1);
  assert.equal(merged[0].required_surface, 'windows-docker-desktop-ni-image');
  assert.deepEqual(merged[0].packet_ids, ['pester-service-model', 'vi-history-local-proof', 'windows-docker-shared-surface']);
  assert.deepEqual(merged[0].governing_requirements, ['REQ-PSM-027', 'REQ-VHLP-006', 'REQ-WDSS-005']);
  assert.deepEqual(merged[0].blocked_requirements, ['REQ-PSM-025', 'REQ-VHLP-001', 'REQ-WDSS-001']);
  assert.deepEqual(merged[0].recommended_commands, [
    'npm run docker:ni:windows:bootstrap',
    'npm run compare:docker:ni:windows:probe',
    'npm run priority:workflow:replay:windows:vi-history'
  ]);
});

test('selectProgramNextStep prefers a requirement before a shared escalation', () => {
  const requirement = {
    type: 'requirement',
    packet_id: 'vi-history-local-proof',
    packet_label: 'VI History Local Proof',
    req_id: 'REQ-VHLP-002'
  };
  const escalation = {
    type: 'escalation',
    required_surface: 'windows-docker-desktop-ni-image'
  };

  assert.equal(selectProgramNextStep([requirement], [escalation]).type, 'requirement');
  assert.equal(selectProgramNextStep([], [escalation]).type, 'escalation');
});

test('selectProgramNextStep falls back to a post-local promotion escalation', () => {
  const promotion = buildPostLocalPromotionEscalation([
    {
      id: 'pester-service-model',
      label: 'Pester Service Model',
      report_path: 'tests/results/_agent/pester-service-model/local-ci/pester-service-model-local-ci-report.json',
      next_step_path: 'tests/results/_agent/pester-service-model/local-ci/pester-service-model-next-step.json'
    },
    {
      id: 'vi-history-local-proof',
      label: 'VI History Local Proof',
      report_path: 'tests/results/_agent/vi-history-local-proof/local-ci/vi-history-local-ci-report.json',
      next_step_path: 'tests/results/_agent/vi-history-local-proof/local-ci/vi-history-local-next-step.json'
    }
  ]);

  assert.equal(selectProgramNextStep([], [], promotion).type, 'escalation');
  assert.equal(selectProgramNextStep([], [], promotion).required_surface, 'integration-or-hosted-proof');
  assert.deepEqual(selectProgramNextStep([], [], promotion).governing_requirements, ['REQ-LPAP-003']);
});

test('program-level local proof contract is documented and exposed through package.json', () => {
  const packageJson = JSON.parse(readRepoFile('package.json'));
  const programDoc = readRepoFile('docs/knowledgebase/Local-Proof-Autonomy-Program.md');
  const programArch = readRepoFile('docs/architecture/local-proof-autonomy-program-control-plane.md');
  const programSrs = readRepoFile('docs/requirements-local-proof-autonomy-program-srs.md');
  const programRtm = readRepoFile('docs/rtm-local-proof-autonomy-program.csv');
  const programPlan = readRepoFile('docs/testing/local-proof-autonomy-program-test-plan.md');
  const pesterSrs = readRepoFile('docs/requirements-pester-service-model-srs.md');
  const pesterRtm = readRepoFile('docs/rtm-pester-service-model.csv');
  const viSrs = readRepoFile('docs/requirements-vi-history-local-proof-srs.md');
  const viRtm = readRepoFile('docs/rtm-vi-history-local-proof.csv');
  const windowsSrs = readRepoFile('docs/requirements-windows-docker-shared-surface-srs.md');
  const windowsRtm = readRepoFile('docs/rtm-windows-docker-shared-surface.csv');

  assert.equal(
    packageJson.scripts['priority:program:local-ci'],
    'node tools/priority/comparevi-local-program-ci.mjs'
  );
  assert.equal(
    packageJson.scripts['priority:program:next-step'],
    'node tools/priority/comparevi-local-program-ci.mjs --print-next-step'
  );
  assert.equal(
    packageJson.scripts['priority:windows-surface:local-ci'],
    'node tools/priority/windows-docker-shared-surface-local-ci.mjs'
  );
  assert.equal(
    packageJson.scripts['priority:windows-surface:next-step'],
    'node tools/priority/windows-docker-shared-surface-local-ci.mjs --print-next-step'
  );

  assert.match(programDoc, /Pester Service Model/i);
  assert.match(programDoc, /VI History Local Proof/i);
  assert.match(programDoc, /Windows Docker Shared Surface/i);
  assert.match(programDoc, /shared `windows-docker-desktop-ni-image` surface/i);
  assert.match(programDoc, /priority:program:local-ci/);
  assert.match(programDoc, /comparevi-local-program-next-step\.json/);
  assert.match(programDoc, /priority:windows-surface:local-ci/);
  assert.match(programDoc, /post-local promotion escalation/i);
  assert.match(programDoc, /integration or hosted proof/i);

  assert.match(programSrs, /REQ-LPAP-001/);
  assert.match(programSrs, /REQ-LPAP-003/);
  assert.match(programSrs, /REQ-LPAP-004/);
  assert.match(programSrs, /promotion escalation instead of `null`/i);
  assert.match(programSrs, /run-scoped audit-surface bundle workspaces/i);
  assert.match(programRtm, /REQ-LPAP-003/);
  assert.match(programRtm, /TEST-LPAP-003/);
  assert.match(programRtm, /REQ-LPAP-004/);
  assert.match(programRtm, /TEST-LPAP-004/);
  assert.match(programPlan, /TEST-LPAP-001/);
  assert.match(programPlan, /TEST-LPAP-003/);
  assert.match(programPlan, /TEST-LPAP-004/);
  assert.match(programArch, /Post-local promotion surface/);
  assert.match(programArch, /integration or hosted proof escalation/i);
  assert.match(programArch, /Bundle workspace safety surface/);
  assert.match(programArch, /surface-bundle\/run-\*/i);

  assert.match(pesterSrs, /REQ-PSM-028/);
  assert.match(pesterRtm, /REQ-PSM-028/);
  assert.match(viSrs, /REQ-VHLP-007/);
  assert.match(viRtm, /REQ-VHLP-007/);
  assert.match(windowsSrs, /REQ-WDSS-006/);
  assert.match(windowsSrs, /REQ-WDSS-008/);
  assert.match(windowsRtm, /REQ-WDSS-006/);
  assert.match(windowsRtm, /REQ-WDSS-008/);
});

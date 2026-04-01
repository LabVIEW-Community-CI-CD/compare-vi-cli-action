#!/usr/bin/env node

import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { applyAutonomyPolicy, deriveEscalations, determinePhase, parseCsv, parseRequirementNumber, rankProofRegressions, rankRequirementGaps, selectNextStep } from '../pester-service-model-local-ci.mjs';

test('parseRequirementNumber extracts numeric requirement ids', () => {
  assert.equal(parseRequirementNumber('REQ-PSM-011'), 11);
  assert.equal(parseRequirementNumber('REQ-PSM-022'), 22);
});

test('determinePhase groups requirement ids into the expected planning phases', () => {
  assert.equal(determinePhase(11), 'foundation');
  assert.equal(determinePhase(14), 'execution-governance');
  assert.equal(determinePhase(18), 'promotion-governance');
  assert.equal(determinePhase(21), 'evidence-governance');
  assert.equal(determinePhase(22), 'autonomy');
});

test('parseCsv handles quoted RTM rows with commas', () => {
  const rows = parseCsv([
    'ReqID,Requirement,Source,Priority,TestID,TestArtifact,CodeRef,Status',
    'REQ-PSM-011,"Execution keeps failure-detail artifacts semantically consistent, even under degradation",docs/requirements.md,High,TEST-PSM-011,"Planned local repro",Invoke-PesterTests.ps1,Gap'
  ].join('\n'));

  assert.equal(rows.length, 1);
  assert.equal(rows[0].ReqID, 'REQ-PSM-011');
  assert.match(rows[0].Requirement, /semantically consistent/);
});

test('rankRequirementGaps prefers earliest high-priority runtime-adjacent gaps', () => {
  const ranked = rankRequirementGaps([
    {
      ReqID: 'REQ-PSM-018',
      Requirement: 'Promotion evidence is retained for baseline comparison.',
      Source: 'docs/requirements.md',
      Priority: 'High',
      TestID: 'TEST-PSM-018',
      TestArtifact: 'Planned promotion coverage',
      CodeRef: 'docs/knowledgebase/Pester-Service-Model.md;.github/workflows/pester-service-model-release-evidence.yml',
      Status: 'Gap'
    },
    {
      ReqID: 'REQ-PSM-011',
      Requirement: 'Execution keeps failure-detail artifacts semantically consistent with summary counts.',
      Source: 'docs/requirements.md',
      Priority: 'High',
      TestID: 'TEST-PSM-011',
      TestArtifact: 'Planned local repro and contract coverage',
      CodeRef: 'Invoke-PesterTests.ps1;tools/Invoke-PesterExecutionFinalize.ps1',
      Status: 'Gap'
    },
    {
      ReqID: 'REQ-PSM-013',
      Requirement: 'The local harness detects unsafe OneDrive-managed roots.',
      Source: 'docs/requirements.md',
      Priority: 'High',
      TestID: 'TEST-PSM-013',
      TestArtifact: 'Planned local path-hygiene coverage',
      CodeRef: 'tools/Run-PesterExecutionOnly.Local.ps1;tools/Session-Lock.ps1',
      Status: 'Gap'
    }
  ]);

  assert.equal(ranked[0].req_id, 'REQ-PSM-011');
  assert.equal(ranked[0].phase, 'foundation');
  assert.match(ranked[0].why_now, /highest-ranked unresolved gap|unresolved High foundation gap/i);
  assert.equal(ranked[1].req_id, 'REQ-PSM-013');
  assert.equal(ranked[2].req_id, 'REQ-PSM-018');
});

test('applyAutonomyPolicy prioritizes active worktree matches and adds bounded local guidance', () => {
  const ranked = rankRequirementGaps([
    {
      ReqID: 'REQ-PSM-011',
      Requirement: 'Execution keeps failure-detail artifacts semantically consistent with summary counts.',
      Source: 'docs/requirements.md',
      Priority: 'High',
      TestID: 'TEST-PSM-011',
      TestArtifact: 'Planned local repro and contract coverage',
      CodeRef: 'Invoke-PesterTests.ps1;tools/Invoke-PesterExecutionFinalize.ps1',
      Status: 'Gap'
    },
    {
      ReqID: 'REQ-PSM-018',
      Requirement: 'Promotion evidence is retained for baseline comparison.',
      Source: 'docs/requirements.md',
      Priority: 'High',
      TestID: 'TEST-PSM-018',
      TestArtifact: 'Planned promotion coverage',
      CodeRef: 'docs/knowledgebase/Pester-Service-Model.md;.github/workflows/pester-service-model-release-evidence.yml',
      Status: 'Gap'
    }
  ]);
  const policy = JSON.parse(fs.readFileSync(path.join(process.cwd(), 'tools/priority/pester-service-model-autonomy-policy.json'), 'utf8'));
  const guided = applyAutonomyPolicy(ranked, policy, ['Invoke-PesterTests.ps1']);

  assert.equal(guided[0].req_id, 'REQ-PSM-011');
  assert.equal(guided[0].active_now, true);
  assert.equal(guided[0].mode, 'local-first');
  assert.ok(guided[0].preferred_commands.length > 0);
  assert.ok(guided[0].stop_conditions.length > 0);
  assert.ok(guided[0].escalate_when.length > 0);
  assert.equal(guided[1].active_now, false);
});

test('rankProofRegressions reopens implemented requirements when representative proof checks fail', () => {
  const regressions = rankProofRegressions([
    {
      id: 'representative-replay',
      owner_requirement: 'REQ-PSM-024',
      status: 'fail',
      blocking: true,
      summary: 'Representative replay crashed on a schema-lite retained run.'
    }
  ], [
    {
      ReqID: 'REQ-PSM-024',
      Requirement: 'Representative retained-artifact replay normalizes legacy retained runs.',
      Source: 'docs/requirements.md',
      Priority: 'High',
      TestID: 'TEST-PSM-024',
      TestArtifact: 'Representative replay proof',
      CodeRef: 'tools/Replay-PesterServiceModelArtifacts.Local.ps1;tools/Invoke-PesterEvidenceClassification.ps1',
      Status: 'Implemented'
    }
  ]);

  assert.equal(regressions.length, 1);
  assert.equal(regressions[0].req_id, 'REQ-PSM-024');
  assert.equal(regressions[0].status, 'Regression');
  assert.equal(regressions[0].proof_check_id, 'representative-replay');
  assert.match(regressions[0].why_now, /regressed/i);
});

test('deriveEscalations emits a machine-readable next step for the Windows-container advisory surface', () => {
  const escalations = deriveEscalations([
    {
      id: 'windows-container-surface',
      owner_requirement: 'REQ-PSM-025',
      status: 'advisory',
      blocking: false,
      summary: 'Windows-container surface is not-windows-host; use the recommended Docker Desktop + NI image commands when a live local proof is required.',
      surface_status: 'not-windows-host',
      host_platform: 'Unix',
      receipt_path: 'tests/results/_agent/pester-service-model/local-ci/windows-container-surface/pester-windows-container-surface.json',
      recommended_commands: [
        'npm run docker:ni:windows:bootstrap',
        'npm run compare:docker:ni:windows:probe',
        'npm run compare:docker:ni:windows'
      ]
    }
  ]);

  assert.equal(escalations.length, 1);
  assert.equal(escalations[0].type, 'escalation');
  assert.equal(escalations[0].governing_requirement, 'REQ-PSM-027');
  assert.equal(escalations[0].blocked_requirement, 'REQ-PSM-025');
  assert.equal(escalations[0].required_surface, 'windows-docker-desktop-ni-image');
  assert.match(escalations[0].reason, /not Windows/i);
  assert.ok(escalations[0].recommended_commands.length > 0);
});

test('selectNextStep prefers requirements first and otherwise yields escalation guidance', () => {
  const requirement = {
    req_id: 'REQ-PSM-012',
    priority: 'High',
    status: 'Gap',
    phase: 'execution-governance',
    score: 1234,
    why_now: 'Need named execution-pack coverage.',
    requirement: 'Named execution pack contract exists.',
    test_id: 'TEST-PSM-012',
    code_refs: ['tools/PesterExecutionPacks.ps1'],
    suggested_loop: ['Add or tighten local coverage first.']
  };
  const escalation = {
    type: 'escalation',
    escalation_id: 'windows-container-live-proof'
  };

  const nextRequirementStep = selectNextStep(requirement, [escalation]);
  assert.equal(nextRequirementStep.type, 'requirement');
  assert.equal(nextRequirementStep.req_id, 'REQ-PSM-012');

  const nextEscalationStep = selectNextStep(null, [escalation]);
  assert.equal(nextEscalationStep.type, 'escalation');
  assert.equal(nextEscalationStep.escalation_id, 'windows-container-live-proof');
});

test('autonomy policy file exists and defines local guidance', () => {
  const policyPath = path.join(process.cwd(), 'tools/priority/pester-service-model-autonomy-policy.json');
  const policy = JSON.parse(fs.readFileSync(policyPath, 'utf8'));

  assert.equal(policy.schema_version, '1.0.0');
  assert.equal(policy.phase_guidance.foundation.mode, 'local-first');
  assert.ok(policy.phase_guidance.foundation.preferred_commands.length > 0);
});

test('Pester local CI uses a run-scoped audit bundle root', () => {
  const source = fs.readFileSync(path.join(process.cwd(), 'tools/priority/pester-service-model-local-ci.mjs'), 'utf8');

  assert.match(source, /createRunScopedBundleRoot/);
  assert.match(source, /surface-bundle/);
  assert.match(source, /run-\$\{Date\.now\(\)\}-\$\{process\.pid\}/);
});

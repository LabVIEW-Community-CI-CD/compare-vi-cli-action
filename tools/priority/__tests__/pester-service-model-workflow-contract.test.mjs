#!/usr/bin/env node

import test from 'node:test';
import assert from 'node:assert/strict';
import path from 'node:path';
import { readFileSync } from 'node:fs';

const repoRoot = process.cwd();

function readRepoFile(relativePath) {
  return readFileSync(path.join(repoRoot, relativePath), 'utf8');
}

test('pester gate pilot routes readiness, execution, and evidence through separate reusable workflows', () => {
  const workflow = readRepoFile('.github/workflows/pester-gate.yml');

  assert.match(workflow, /name:\s+Pester gate \(service model pilot\)/);
  assert.match(workflow, /workflow_call:/);
  assert.match(workflow, /workflow_dispatch:/);
  assert.match(workflow, /jobs:\s*\n\s*readiness:\s*\n\s+uses:\s+\.\s*\/\.github\/workflows\/selfhosted-readiness\.yml/);
  assert.match(workflow, /\n\s*pester-run:\s*\n\s+needs:\s+readiness\s*\n\s+if:\s+always\(\)\s*\n\s+uses:\s+\.\s*\/\.github\/workflows\/pester-run\.yml/);
  assert.match(workflow, /readiness_artifact_name:\s+\$\{\{\s*needs\.readiness\.outputs\.receipt_artifact_name\s*\}\}/);
  assert.match(workflow, /checkout_repository:\s+\$\{\{\s*inputs\.checkout_repository \|\| github\.repository\s*\}\}/);
  assert.match(workflow, /checkout_ref:\s+\$\{\{\s*inputs\.checkout_ref \|\| github\.sha\s*\}\}/);
  assert.match(workflow, /\n\s*pester-evidence:\s*\n\s+needs:\s+\[readiness, pester-run\]\s*\n\s+if:\s+always\(\)\s*\n\s+uses:\s+\.\s*\/\.github\/workflows\/pester-evidence\.yml/);
});

test('selfhosted readiness owns host-plane certification and emits a receipt artifact', () => {
  const workflow = readRepoFile('.github/workflows/selfhosted-readiness.yml');

  assert.match(workflow, /name:\s+Self-hosted readiness/);
  assert.match(workflow, /workflow_call:/);
  assert.match(workflow, /receipt_status:/);
  assert.match(workflow, /runs-on:\s*\[self-hosted, Windows, X64, comparevi, capability-ingress\]/);
  assert.match(workflow, /repository:\s+\$\{\{\s*inputs\.checkout_repository \|\| github\.repository\s*\}\}/);
  assert.match(workflow, /ref:\s+\$\{\{\s*inputs\.checkout_ref \|\| github\.sha\s*\}\}/);
  assert.match(workflow, /Validate runner label contract/);
  assert.match(workflow, /Probe session-lock health/);
  assert.match(workflow, /Resolve \.NET host toolchain/);
  assert.match(workflow, /Invoke-DockerRuntimeManager\.ps1/);
  assert.match(workflow, /Verify LVCompare and idle LabVIEW state/);
  assert.match(workflow, /Upload readiness receipt/);
  assert.match(workflow, /pester-selfhosted-readiness/);
  assert.match(workflow, /freshnessWindowSeconds = 900/);
});

test('pester run is execution-only and validates the readiness receipt before dispatch', () => {
  const workflow = readRepoFile('.github/workflows/pester-run.yml');

  assert.match(workflow, /name:\s+Pester run/);
  assert.match(workflow, /name:\s+Pester \(execution only\)/);
  assert.match(workflow, /if:\s+\$\{\{\s*inputs\.readiness_status == 'ready'\s*\}\}/);
  assert.match(workflow, /repository:\s+\$\{\{\s*inputs\.checkout_repository \|\| github\.repository\s*\}\}/);
  assert.match(workflow, /ref:\s+\$\{\{\s*inputs\.checkout_ref \|\| github\.sha\s*\}\}/);
  assert.match(workflow, /Download readiness receipt artifact/);
  assert.match(workflow, /Validate readiness receipt/);
  assert.match(workflow, /selfhosted-readiness\.json/);
  assert.match(workflow, /Run Pester tests via local dispatcher/);
  assert.match(workflow, /pester-run-receipt\.json/);
  assert.match(workflow, /Upload raw Pester execution artifact/);
  assert.doesNotMatch(workflow, /Install Pester/);
  assert.doesNotMatch(workflow, /Invoke-DockerRuntimeManager\.ps1/);
  assert.doesNotMatch(workflow, /Write-PesterSummaryToStepSummary\.ps1/);
  assert.doesNotMatch(workflow, /Invoke-DevDashboard\.ps1/);
});

test('pester evidence classifies seam defects explicitly from raw execution outputs', () => {
  const workflow = readRepoFile('.github/workflows/pester-evidence.yml');

  assert.match(workflow, /name:\s+Pester evidence/);
  assert.match(workflow, /runs-on:\s+ubuntu-latest/);
  assert.match(workflow, /Download raw execution artifact/);
  assert.match(workflow, /Validate execution receipt artifact/);
  assert.match(workflow, /execution-receipt-missing/);
  assert.match(workflow, /Write-PesterSummaryToStepSummary\.ps1/);
  assert.match(workflow, /Ensure-SessionIndex\.ps1/);
  assert.match(workflow, /Invoke-DevDashboard\.ps1/);
  assert.match(workflow, /classification = 'seam-defect'/);
  assert.match(workflow, /execution-receipt-seam-defect/);
  assert.match(workflow, /Upload evidence artifact/);
  assert.match(workflow, /Propagate gate outcome/);
});

test('knowledgebase documents the additive service model and keeps the monolith as the current baseline', () => {
  const doc = readRepoFile('docs/knowledgebase/Pester-Service-Model.md');

  assert.match(doc, /legacy Pester control plane couples four concerns into one self-hosted transaction/i);
  assert.match(doc, /selfhosted-readiness\.yml/);
  assert.match(doc, /pester-run\.yml/);
  assert.match(doc, /pester-evidence\.yml/);
  assert.match(doc, /readiness receipt/i);
  assert.match(doc, /execution receipt/i);
  assert.match(doc, /existing required gate remains in place/i);
});

test('trusted PR pilot router only runs self-hosted service-model proof for workflow dispatch or same-owner labeled PR heads', () => {
  const workflow = readRepoFile('.github/workflows/pester-service-model-on-label.yml');

  assert.match(workflow, /name:\s+Pester service-model pilot on trusted PR label/);
  assert.match(workflow, /pull_request_target:/);
  assert.match(workflow, /types:\s*\[labeled, reopened, synchronize\]/);
  assert.match(workflow, /workflow_dispatch:/);
  assert.match(workflow, /labels -contains 'pester-service-model'/);
  assert.match(workflow, /head\.repo\.owner\.login/);
  assert.match(workflow, /\$trustMode = 'same-owner-head'/);
  assert.match(workflow, /reason = 'untrusted-cross-owner-fork'/);
  assert.match(workflow, /uses:\s+\.\s*\/\.github\/workflows\/pester-gate\.yml/);
});

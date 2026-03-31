#!/usr/bin/env node

import test from 'node:test';
import assert from 'node:assert/strict';
import path from 'node:path';
import { readFileSync } from 'node:fs';

const repoRoot = process.cwd();

function readRepoFile(relativePath) {
  return readFileSync(path.join(repoRoot, relativePath), 'utf8');
}

test('pester gate pilot routes context, selection, readiness, execution, and evidence through separate reusable workflows', () => {
  const workflow = readRepoFile('.github/workflows/pester-gate.yml');

  assert.match(workflow, /name:\s+Pester gate \(service model pilot\)/);
  assert.match(workflow, /workflow_call:/);
  assert.match(workflow, /workflow_dispatch:/);
  assert.match(workflow, /route_should_run:/);
  assert.match(workflow, /route_reason:/);
  assert.match(workflow, /route_trust_mode:/);
  assert.match(workflow, /group:\s+pester-gate-\$\{\{\s*inputs\.sample_id \|\| github\.ref\s*\}\}/);
  assert.match(workflow, /jobs:\s*\n\s*skipped:\s*\n\s+if:\s+\$\{\{\s*!fromJSON\(inputs\.route_should_run \|\| 'true'\)\s*\}\}/);
  assert.match(workflow, /\n\s*context:\s*\n\s+if:\s+\$\{\{\s*fromJSON\(inputs\.route_should_run \|\| 'true'\)\s*\}\}\s*\n\s+uses:\s+\.\s*\/\.github\/workflows\/pester-context\.yml/);
  assert.match(workflow, /\n\s*readiness:\s*\n\s+needs:\s+context\s*\n\s+if:\s+\$\{\{\s*always\(\) && fromJSON\(inputs\.route_should_run \|\| 'true'\) && needs\.context\.outputs\.receipt_status == 'ready'\s*\}\}\s*\n\s+uses:\s+\.\s*\/\.github\/workflows\/selfhosted-readiness\.yml/);
  assert.match(workflow, /\n\s*selection:\s*\n\s+needs:\s+context\s*\n\s+if:\s+\$\{\{\s*always\(\) && fromJSON\(inputs\.route_should_run \|\| 'true'\) && needs\.context\.outputs\.receipt_status == 'ready'\s*\}\}\s*\n\s+uses:\s+\.\s*\/\.github\/workflows\/pester-selection\.yml/);
  assert.match(workflow, /\n\s*pester-run:\s*\n\s+needs:\s+\[context, readiness, selection\]\s*\n\s+if:\s+\$\{\{\s*always\(\) && fromJSON\(inputs\.route_should_run \|\| 'true'\)\s*\}\}\s*\n\s+uses:\s+\.\s*\/\.github\/workflows\/pester-run\.yml/);
  assert.match(workflow, /context_status:\s+\$\{\{\s*needs\.context\.outputs\.receipt_status\s*\|\|\s*needs\.context\.result/);
  assert.match(workflow, /context_artifact_name:\s+\$\{\{\s*needs\.context\.outputs\.receipt_artifact_name\s*\|\|\s*'pester-context'/);
  assert.match(workflow, /readiness_artifact_name:\s+\$\{\{\s*needs\.readiness\.outputs\.receipt_artifact_name\s*\|\|\s*'pester-readiness'/);
  assert.match(workflow, /readiness_status:\s+\$\{\{\s*needs\.readiness\.outputs\.receipt_status\s*\|\|\s*needs\.readiness\.result/);
  assert.match(workflow, /selection_artifact_name:\s+\$\{\{\s*needs\.selection\.outputs\.receipt_artifact_name\s*\|\|\s*'pester-selection'/);
  assert.match(workflow, /selection_status:\s+\$\{\{\s*needs\.selection\.outputs\.receipt_status\s*\|\|\s*needs\.selection\.result/);
  assert.match(workflow, /checkout_repository:\s+\$\{\{\s*inputs\.checkout_repository \|\| github\.repository\s*\}\}/);
  assert.match(workflow, /checkout_ref:\s+\$\{\{\s*inputs\.checkout_ref \|\| github\.sha\s*\}\}/);
  assert.match(workflow, /\n\s*pester-evidence:\s*\n\s+needs:\s+\[context, readiness, selection, pester-run\]\s*\n\s+if:\s+\$\{\{\s*always\(\) && fromJSON\(inputs\.route_should_run \|\| 'true'\)\s*\}\}\s*\n\s+uses:\s+\.\s*\/\.github\/workflows\/pester-evidence\.yml/);
  assert.match(workflow, /context_status:\s+\$\{\{\s*needs\.context\.outputs\.receipt_status\s*\|\|\s*needs\.context\.result/);
  assert.match(workflow, /selection_status:\s+\$\{\{\s*needs\.selection\.outputs\.receipt_status\s*\|\|\s*needs\.selection\.result/);
  assert.match(workflow, /execution_job_result:\s+\$\{\{\s*needs\.pester-run\.outputs\.execution_status\s*\|\|\s*needs\.pester-run\.result/);
  assert.match(workflow, /execution_receipt_artifact_name:\s+\$\{\{\s*needs\.pester-run\.outputs\.execution_receipt_artifact_name/);
  assert.match(workflow, /### Pester gate \(service model pilot\)/);
});

test('pester context owns repo/control-plane receipts before host readiness begins', () => {
  const workflow = readRepoFile('.github/workflows/pester-context.yml');

  assert.match(workflow, /name:\s+Pester context/);
  assert.match(workflow, /workflow_call:/);
  assert.match(workflow, /receipt_status:/);
  assert.match(workflow, /standing_priority_issue:/);
  assert.match(workflow, /standing_priority_reason:/);
  assert.match(workflow, /runs-on:\s+ubuntu-latest/);
  assert.match(workflow, /Resolve standing-priority context/);
  assert.match(workflow, /run-sync-standing-priority\.mjs --materialize-cache/);
  assert.match(workflow, /pester-context-receipt@v1/);
  assert.match(workflow, /Upload context receipt/);
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

test('pester selection owns pack shaping and dispatcher profile resolution before execution begins', () => {
  const workflow = readRepoFile('.github/workflows/pester-selection.yml');

  assert.match(workflow, /name:\s+Pester selection/);
  assert.match(workflow, /workflow_call:/);
  assert.match(workflow, /receipt_status:/);
  assert.match(workflow, /receipt_artifact_name:/);
  assert.match(workflow, /Normalize include_integration/);
  assert.match(workflow, /Shape include patterns/);
  assert.match(workflow, /Resolve dispatcher profile/);
  assert.match(workflow, /pester-selection-receipt@v1/);
  assert.match(workflow, /integrationMode/);
  assert.match(workflow, /fixtureRequired/);
  assert.match(workflow, /Upload selection receipt/);
});

test('pester run is execution-only and validates context, readiness, and selection receipts before dispatch', () => {
  const workflow = readRepoFile('.github/workflows/pester-run.yml');

  assert.match(workflow, /name:\s+Pester run/);
  assert.match(workflow, /name:\s+Pester \(execution only\)/);
  assert.match(workflow, /if:\s+\$\{\{\s*inputs\.context_status == 'ready' && inputs\.readiness_status == 'ready' && inputs\.selection_status == 'ready'\s*\}\}/);
  assert.match(workflow, /execution_status:/);
  assert.match(workflow, /execution_receipt_artifact_name:/);
  assert.match(workflow, /repository:\s+\$\{\{\s*inputs\.checkout_repository \|\| github\.repository\s*\}\}/);
  assert.match(workflow, /ref:\s+\$\{\{\s*inputs\.checkout_ref \|\| github\.sha\s*\}\}/);
  assert.match(workflow, /Download context receipt artifact/);
  assert.match(workflow, /Validate context receipt/);
  assert.match(workflow, /pester-context\.json/);
  assert.match(workflow, /Download readiness receipt artifact/);
  assert.match(workflow, /Validate readiness receipt/);
  assert.match(workflow, /selfhosted-readiness\.json/);
  assert.match(workflow, /Download selection receipt artifact/);
  assert.match(workflow, /Validate selection receipt/);
  assert.match(workflow, /pester-selection\.json/);
  assert.match(workflow, /selection-blocked/);
  assert.match(workflow, /Run Pester tests via local dispatcher/);
  assert.match(workflow, /pester-run-receipt\.json/);
  assert.match(workflow, /Upload raw Pester execution artifact/);
  assert.match(workflow, /Emit execution contract/);
  assert.match(workflow, /Upload execution contract artifact/);
  assert.doesNotMatch(workflow, /Normalize include_integration/);
  assert.doesNotMatch(workflow, /needs\.normalize/);
  assert.doesNotMatch(workflow, /Install Pester/);
  assert.doesNotMatch(workflow, /Invoke-DockerRuntimeManager\.ps1/);
  assert.doesNotMatch(workflow, /Write-PesterSummaryToStepSummary\.ps1/);
  assert.doesNotMatch(workflow, /Invoke-DevDashboard\.ps1/);
});

test('pester evidence distinguishes context-blocked, selection-blocked, and readiness-blocked skips from seam defects', () => {
  const workflow = readRepoFile('.github/workflows/pester-evidence.yml');

  assert.match(workflow, /name:\s+Pester evidence/);
  assert.match(workflow, /runs-on:\s+ubuntu-latest/);
  assert.match(workflow, /execution_receipt_artifact_name:/);
  assert.match(workflow, /Download execution receipt artifact/);
  assert.match(workflow, /Download raw execution artifact/);
  assert.match(workflow, /Validate execution receipt artifact/);
  assert.match(workflow, /execution-receipt-missing/);
  assert.match(workflow, /Write-PesterSummaryToStepSummary\.ps1/);
  assert.match(workflow, /Ensure-SessionIndex\.ps1/);
  assert.match(workflow, /Invoke-DevDashboard\.ps1/);
  assert.match(workflow, /classification = 'seam-defect'/);
  assert.match(workflow, /\$classification = 'context-blocked'/);
  assert.match(workflow, /\$classification = 'selection-blocked'/);
  assert.match(workflow, /\$classification = 'readiness-blocked'/);
  assert.match(workflow, /\$contextStatus -ne 'ready'/);
  assert.match(workflow, /\$selectionStatus -ne 'ready'/);
  assert.match(workflow, /\$executionReceiptStatus -eq 'selection-blocked'/);
  assert.match(workflow, /\$executionReceiptStatus -eq 'context-blocked'/);
  assert.match(workflow, /\$readinessStatus -ne 'ready' -and \$executionJobResult -in @\('skipped','cancelled'\)/);
  assert.match(workflow, /raw-artifact-download=/);
  assert.match(workflow, /execution-receipt-seam-defect/);
  assert.match(workflow, /Upload evidence artifact/);
  assert.match(workflow, /Propagate gate outcome/);
});

test('knowledgebase documents the additive service model and keeps the monolith as the current baseline', () => {
  const doc = readRepoFile('docs/knowledgebase/Pester-Service-Model.md');

  assert.match(doc, /legacy Pester control plane couples four concerns into one self-hosted transaction/i);
  assert.match(doc, /pester-context\.yml/);
  assert.match(doc, /pester-selection\.yml/);
  assert.match(doc, /selfhosted-readiness\.yml/);
  assert.match(doc, /pester-run\.yml/);
  assert.match(doc, /pester-evidence\.yml/);
  assert.match(doc, /Context certifies repo\/control-plane assumptions/i);
  assert.match(doc, /Selection resolves integration mode, include patterns, and dispatcher profile into a receipt/i);
  assert.match(doc, /readiness receipt/i);
  assert.match(doc, /execution receipt/i);
  assert.match(doc, /existing required gate remains in place/i);
});

test('trusted PR pilot router only runs self-hosted service-model proof for workflow dispatch or same-owner labeled PR heads', () => {
  const workflow = readRepoFile('.github/workflows/pester-service-model-on-label.yml');

  assert.match(workflow, /name:\s+Pester service-model pilot on trusted PR label/);
  assert.match(workflow, /pull_request_target:/);
  assert.match(workflow, /permissions:\s*\n\s+contents:\s+read\s*\n\s+issues:\s+read\s*\n\s+pull-requests:\s+read/);
  assert.match(workflow, /types:\s*\[labeled, reopened, synchronize\]/);
  assert.doesNotMatch(workflow, /paths-ignore:/);
  assert.match(workflow, /group:\s+trusted-pilot-router-\$\{\{\s*github\.event\.pull_request\.number \|\| github\.event\.inputs\.sample_id \|\| github\.ref\s*\}\}/);
  assert.match(workflow, /workflow_dispatch:/);
  assert.match(workflow, /labels -contains 'pester-service-model'/);
  assert.match(workflow, /PR_LABELS_JSON:\s+\$\{\{\s*toJson\(github\.event\.pull_request\.labels\.\*\.name\)\s*\}\}/);
  assert.match(workflow, /ConvertFrom-Json -InputObject \$env:PR_LABELS_JSON/);
  assert.match(workflow, /head\.repo\.owner\.login/);
  assert.match(workflow, /Add-Content -Path \$env:GITHUB_OUTPUT -Value "should_run=\$shouldRun"/);
  assert.match(workflow, /### Trusted pilot routing/);
  assert.match(workflow, /\$trustMode = 'same-owner-head'/);
  assert.match(workflow, /reason = 'untrusted-cross-owner-fork'/);
  assert.match(workflow, /uses:\s+\.\s*\/\.github\/workflows\/pester-gate\.yml/);
  assert.match(workflow, /route_should_run:\s+\$\{\{\s*needs\.trust-context\.outputs\.should_run \|\| 'false'\s*\}\}/);
  assert.match(workflow, /route_reason:\s+\$\{\{\s*needs\.trust-context\.outputs\.reason \|\| ''\s*\}\}/);
  assert.match(workflow, /route_trust_mode:\s+\$\{\{\s*needs\.trust-context\.outputs\.trust_mode \|\| ''\s*\}\}/);
  assert.match(workflow, /include_integration:\s+\$\{\{\s*'true'\s*\}\}/);
});

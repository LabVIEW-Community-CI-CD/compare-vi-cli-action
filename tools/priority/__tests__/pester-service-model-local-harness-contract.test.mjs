#!/usr/bin/env node

import test from 'node:test';
import assert from 'node:assert/strict';
import path from 'node:path';
import { readFileSync } from 'node:fs';

const repoRoot = process.cwd();

function readRepoFile(relativePath) {
  return readFileSync(path.join(repoRoot, relativePath), 'utf8');
}

test('package.json exposes the local execution harness as a first-class entrypoint', () => {
  const packageJson = JSON.parse(readRepoFile('package.json'));
  assert.equal(
    packageJson.scripts['tests:execution:local'],
    'pwsh -NoLogo -NoProfile -File tools/Run-PesterExecutionOnly.Local.ps1'
  );
  assert.equal(
    packageJson.scripts['tests:replay:local'],
    'pwsh -NoLogo -NoProfile -File tools/Replay-PesterServiceModelArtifacts.Local.ps1'
  );
  assert.equal(
    packageJson.scripts['tests:replay:representative'],
    'pwsh -NoLogo -NoProfile -Command "& \'tools/Replay-PesterServiceModelArtifacts.Local.ps1\' -RawArtifactDir \'tests/fixtures/pester-service-model/legacy-results-xml-truncated/raw\' -ExecutionReceiptPath \'tests/fixtures/pester-service-model/legacy-results-xml-truncated/pester-run-receipt.json\' -WorkspaceResultsDir \'tests/results/pester-replay-representative\'"'
  );
  assert.equal(
    packageJson.scripts['tests:windows-surface:probe'],
    'pwsh -NoLogo -NoProfile -File tools/Invoke-PesterWindowsContainerSurfaceProbe.ps1'
  );
  assert.equal(
    packageJson.scripts['tests:pack:comparevi'],
    'pwsh -NoLogo -NoProfile -File tools/Run-PesterExecutionOnly.Local.ps1 -ExecutionPack comparevi'
  );
  assert.equal(
    packageJson.scripts['tests:pack:dispatcher'],
    'pwsh -NoLogo -NoProfile -File tools/Run-PesterExecutionOnly.Local.ps1 -ExecutionPack dispatcher'
  );
  assert.equal(
    packageJson.scripts['tests:pack:workflow'],
    'pwsh -NoLogo -NoProfile -File tools/Run-PesterExecutionOnly.Local.ps1 -ExecutionPack workflow'
  );
  assert.equal(
    packageJson.scripts['priority:pester:next-step'],
    'node tools/priority/pester-service-model-local-ci.mjs --print-next-step'
  );
});

test('local execution harness owns lock lifecycle, preflight, dispatch, and receipt generation', () => {
  const harness = readRepoFile('tools/Run-PesterExecutionOnly.Local.ps1');
  const packs = readRepoFile('tools/PesterExecutionPacks.ps1');
  const invoker = readRepoFile('scripts/Pester-Invoker.psm1');

  assert.match(harness, /\[string\]\$ExecutionPack = 'full'/);
  assert.match(harness, /PesterExecutionPacks\.ps1/);
  assert.match(harness, /Resolve-PesterExecutionPack -ExecutionPack \$effectiveExecutionPack/);
  assert.match(harness, /\[string\]\$SessionLockRoot/);
  assert.match(harness, /\$requestedSessionLockRoot = if \(\[string\]::IsNullOrWhiteSpace\(\$SessionLockRoot\)\)/);
  assert.match(harness, /\$resolvedSessionLockRoot = \$requestedSessionLockRoot/);
  assert.match(harness, /\[ValidateSet\('auto', 'relocate', 'block', 'off'\)\]\s*\[string\]\$PathHygieneMode = 'auto'/);
  assert.match(harness, /PesterPathHygiene\.ps1/);
  assert.match(harness, /Resolve-PesterPathHygienePlan -ResultsPath \$requestedResultsPath -SessionLockRoot \$requestedSessionLockRoot -Mode \$PathHygieneMode -SafeRoot \$PathHygieneSafeRoot/);
  assert.match(harness, /path-hygiene-blocked/);
  assert.match(harness, /-Action Acquire -Group \$SessionLockGroup -LockRoot \$resolvedSessionLockRoot/);
  assert.match(harness, /-Action Release/);
  assert.match(harness, /SESSION_LOCK_ROOT = \$resolvedSessionLockRoot/);
  assert.match(harness, /Invoke-RunnerUnblockGuardLocal/);
  assert.match(harness, /Invoke-PrepareFixturesLocal/);
  assert.match(harness, /Get-Command dotnet/);
  assert.match(harness, /Resolve-LVComparePath/);
  assert.match(harness, /Invoke-PesterTests\.ps1/);
  assert.match(harness, /Invoke-PesterExecutionPostprocess\.ps1/);
  assert.match(harness, /Invoke-PesterExecutionTelemetry\.ps1/);
  assert.match(harness, /unsupported-schema/);
  assert.match(harness, /dispatcher-github-output\.txt/);
  assert.match(harness, /\$originalGitHubOutput = \$env:GITHUB_OUTPUT/);
  assert.match(harness, /pester-execution-receipt@v1/);
  assert.match(harness, /pester-execution-contract/);
  assert.match(harness, /source = 'local-harness'/);
  assert.match(harness, /results-xml-truncated/);
  assert.match(harness, /telemetryStatus/);
  assert.match(harness, /telemetryLastKnownPhase/);
  assert.match(harness, /telemetryEventCount/);
  assert.match(harness, /selectionExecutionPack = \[string\]\$executionPackResolution\.executionPack/);
  assert.match(harness, /effectiveIncludePatterns = @\(\$executionPackResolution\.effectiveIncludePatterns\)/);
  assert.match(harness, /summaryPresent/);
  assert.match(harness, /sessionLockRoot = ConvertTo-PortablePath \$resolvedSessionLockRoot/);
  assert.match(harness, /pathHygiene = \$pathHygieneRecord/);
  assert.match(packs, /function Resolve-PesterExecutionPack/);
  assert.match(packs, /comparevi/);
  assert.match(packs, /dispatcher/);
  assert.match(packs, /workflow/);
  assert.match(invoker, /ConvertTo-Json -Depth 8 -Compress/);
});

test('dispatcher path delegates summary, artifact, and session-index side effects to the execution finalize helper', () => {
  const dispatcher = readRepoFile('Invoke-PesterTests.ps1');
  const finalize = readRepoFile('tools/Invoke-PesterExecutionFinalize.ps1');
  const publication = readRepoFile('tools/Invoke-PesterExecutionPublication.ps1');

  assert.match(dispatcher, /Invoke-PesterExecutionFinalize\.ps1/);
  assert.match(dispatcher, /pester-execution-finalize-context@v1/);
  assert.match(dispatcher, /Invoke-ExecutionFinalizeHelper\s+-SummaryText\s+\$summary\s+-SummaryPayload\s+\$jsonObj\s+-ArtifactTrail\s+\$script:artifactTrail/);
  assert.match(dispatcher, /Invoke-ExecutionFinalizeHelper\s+-ReuseExistingContext/);
  assert.match(dispatcher, /function New-ExecutionPublicationPayload/);
  assert.match(dispatcher, /Leak detected: pester-leak-report\.json will be emitted during finalize\./);
  assert.doesNotMatch(dispatcher, /\$env:GITHUB_STEP_SUMMARY/);
  assert.doesNotMatch(dispatcher, /Write-ArtifactManifest\s+-Directory/);
  assert.doesNotMatch(dispatcher, /Write-SessionIndex\s+-ResultsDirectory/);
  assert.match(finalize, /Write-LeakReportFromPayload/);
  assert.match(finalize, /publicationToolPath = Join-Path \$PSScriptRoot 'Invoke-PesterExecutionPublication\.ps1'/);
  assert.match(finalize, /pester-artifacts\.json/);
  assert.match(finalize, /session-index\.json/);
  assert.match(finalize, /compare-report\.html/);
  assert.match(finalize, /results-index\.html/);
  assert.match(publication, /Write-PesterSummaryToStepSummary\.ps1/);
  assert.match(publication, /Write-SessionIndexSummary\.ps1/);
  assert.match(publication, /pester-execution-publication@v1/);
});

test('knowledgebase documents the local harness as the workflow-shell-free execution entrypoint', () => {
  const doc = readRepoFile('docs/knowledgebase/Pester-Service-Model.md');

  assert.match(doc, /Run-PesterExecutionOnly\.Local\.ps1/);
  assert.match(doc, /Replay-PesterServiceModelArtifacts\.Local\.ps1/);
  assert.match(doc, /tests:replay:representative/);
  assert.match(doc, /tests:windows-surface:probe/);
  assert.match(doc, /without the workflow shell/i);
  assert.match(doc, /lock,\s+LV guard,\s+fixture prep,\s+dispatcher profile,\s+dispatch,\s+execution postprocess,\s+and local execution receipt/i);
  assert.match(doc, /tests:pack:comparevi/);
  assert.match(doc, /tests:replay:local/);
});

test('execution-layer assurance packet traces the local harness in the SRS, RTM, and test plan', () => {
  const srs = readRepoFile('docs/requirements-pester-service-model-srs.md');
  const rtm = readRepoFile('docs/rtm-pester-service-model.csv');
  const plan = readRepoFile('docs/testing/pester-service-model-test-plan.md');

  assert.match(srs, /Run-PesterExecutionOnly\.Local\.ps1/);
  assert.match(srs, /mirrors that slice locally without the workflow shell/i);
  assert.match(rtm, /tools\/Run-PesterExecutionOnly\.Local\.ps1/);
  assert.match(rtm, /pester-service-model-local-harness-contract\.test\.mjs/);
  assert.match(plan, /Run-PesterExecutionOnly\.Local\.ps1/);
  assert.match(plan, /Local harness contract tests pass/i);
});

test('assurance packet records forward execution-pack, path-hygiene, replay, and side-effect requirements', () => {
  const srs = readRepoFile('docs/requirements-pester-service-model-srs.md');
  const rtm = readRepoFile('docs/rtm-pester-service-model.csv');
  const plan = readRepoFile('docs/testing/pester-service-model-test-plan.md');
  const doc = readRepoFile('docs/knowledgebase/Pester-Service-Model.md');

  assert.match(srs, /REQ-PSM-012/);
  assert.match(srs, /named execution pack or test group/i);
  assert.match(srs, /REQ-PSM-013/);
  assert.match(srs, /OneDrive-managed directories/i);
  assert.match(srs, /REQ-PSM-014/);
  assert.match(srs, /reproducible locally from retained artifacts/i);
  assert.match(srs, /REQ-PSM-015/);
  assert.match(srs, /Dispatcher responsibilities shall stop at declared test execution/i);
  assert.match(srs, /REQ-PSM-016/);
  assert.match(srs, /durable progress telemetry/i);
  assert.match(srs, /REQ-PSM-017/);
  assert.match(srs, /schema contracts with version-governed readers/i);
  assert.match(srs, /REQ-PSM-018/);
  assert.match(srs, /retained requirement-to-run evidence/i);
  assert.match(srs, /REQ-PSM-019/);
  assert.match(srs, /Stable operator-facing entrypoints/i);
  assert.match(srs, /REQ-PSM-020/);
  assert.match(srs, /retain provenance/i);
  assert.match(srs, /REQ-PSM-021/);
  assert.match(srs, /machine-readable operator outcomes/i);
  assert.match(srs, /REQ-PSM-022/);
  assert.match(srs, /ranked backlog and a selected next requirement/i);
  assert.match(srs, /REQ-PSM-023/);
  assert.match(srs, /active-worktree signals, and stop conditions/i);
  assert.match(srs, /REQ-PSM-024/);
  assert.match(srs, /representative retained-artifact replay/i);
  assert.match(srs, /REQ-PSM-025/);
  assert.match(srs, /Docker Desktop Windows engine and the pinned NI Windows image/i);
  assert.match(srs, /REQ-PSM-026/);
  assert.match(srs, /reopen implemented requirements when representative proof checks regress/i);
  assert.match(srs, /REQ-PSM-027/);
  assert.match(srs, /machine-readable escalation step/i);
  assert.match(srs, /REQ-PSM-028/);
  assert.match(srs, /shared local proof program selector/i);
  assert.match(srs, /REQ-PSM-029/);
  assert.match(srs, /secondary harness or evidence truth/i);

  assert.match(rtm, /REQ-PSM-012/);
  assert.match(rtm, /TEST-PSM-012/);
  assert.match(rtm, /REQ-PSM-013/);
  assert.match(rtm, /TEST-PSM-013/);
  assert.match(rtm, /REQ-PSM-014/);
  assert.match(rtm, /TEST-PSM-014/);
  assert.match(rtm, /REQ-PSM-015/);
  assert.match(rtm, /TEST-PSM-015/);
  assert.match(rtm, /REQ-PSM-016/);
  assert.match(rtm, /TEST-PSM-016/);
  assert.match(rtm, /REQ-PSM-017/);
  assert.match(rtm, /TEST-PSM-017/);
  assert.match(rtm, /REQ-PSM-018/);
  assert.match(rtm, /TEST-PSM-018/);
  assert.match(rtm, /REQ-PSM-019/);
  assert.match(rtm, /TEST-PSM-019/);
  assert.match(rtm, /REQ-PSM-020/);
  assert.match(rtm, /TEST-PSM-020/);
  assert.match(rtm, /REQ-PSM-021/);
  assert.match(rtm, /TEST-PSM-021/);
  assert.match(rtm, /REQ-PSM-022/);
  assert.match(rtm, /TEST-PSM-022/);
  assert.match(rtm, /REQ-PSM-023/);
  assert.match(rtm, /TEST-PSM-023/);
  assert.match(rtm, /REQ-PSM-024/);
  assert.match(rtm, /TEST-PSM-024/);
  assert.match(rtm, /REQ-PSM-025/);
  assert.match(rtm, /TEST-PSM-025/);
  assert.match(rtm, /REQ-PSM-026/);
  assert.match(rtm, /TEST-PSM-026/);
  assert.match(rtm, /REQ-PSM-027/);
  assert.match(rtm, /TEST-PSM-027/);
  assert.match(rtm, /REQ-PSM-028/);
  assert.match(rtm, /TEST-PSM-028/);
  assert.match(rtm, /REQ-PSM-029/);
  assert.match(rtm, /TEST-PSM-029/);

  assert.match(plan, /TEST-PSM-012[\s\S]*named-pack and execution-group coverage/i);
  assert.match(plan, /TEST-PSM-013[\s\S]*local path-hygiene coverage/i);
  assert.match(plan, /Run-PesterExecutionOnly\.Local\.PathHygiene\.Tests\.ps1/);
  assert.match(plan, /TEST-PSM-014[\s\S]*retained-artifact replay coverage/i);
  assert.match(plan, /Replay-PesterServiceModelArtifacts\.Local\.Tests\.ps1/);
  assert.match(plan, /TEST-PSM-015[\s\S]*side-effect ownership coverage/i);
  assert.match(plan, /TEST-PSM-016[\s\S]*durable progress telemetry coverage/i);
  assert.match(plan, /TEST-PSM-017[\s\S]*schema-governance coverage/i);
  assert.match(plan, /TEST-PSM-018[\s\S]*promotion-comparison coverage/i);
  assert.match(plan, /TEST-PSM-019[\s\S]*named entrypoint coverage/i);
  assert.match(plan, /TEST-PSM-020[\s\S]*provenance coverage/i);
  assert.match(plan, /TEST-PSM-021[\s\S]*operator-outcome coverage/i);
  assert.match(plan, /TEST-PSM-022[\s\S]*local autonomy-loop coverage/i);
  assert.match(plan, /TEST-PSM-023[\s\S]*autonomy-policy and stop-condition coverage/i);
  assert.match(plan, /TEST-PSM-024[\s\S]*representative retained-artifact replay coverage/i);
  assert.match(plan, /Replay-PesterServiceModelRepresentativeArtifact\.Tests\.ps1/);
  assert.match(plan, /TEST-PSM-025[\s\S]*windows-container surface coverage/i);
  assert.match(plan, /Invoke-PesterWindowsContainerSurfaceProbe\.Tests\.ps1/);
  assert.match(plan, /TEST-PSM-026[\s\S]*proof-check aware autonomy coverage/i);
  assert.match(plan, /TEST-PSM-027[\s\S]*next-step escalation coverage/i);
  assert.match(plan, /TEST-PSM-028[\s\S]*shared local-program selector coverage/i);
  assert.match(plan, /TEST-PSM-029[\s\S]*secondary-authority coverage/i);

  assert.match(doc, /named execution pack or test group/i);
  assert.match(doc, /OneDrive-like paths are path-hygiene risk/i);
  assert.match(doc, /PesterPathHygiene\.ps1/);
  assert.match(doc, /PathHygieneMode/i);
  assert.match(doc, /reproducible locally from mounted artifacts/i);
  assert.match(doc, /Invoke-PesterEvidenceClassification\.ps1/);
  assert.match(doc, /dispatcher-events\.ndjson/i);
  assert.match(doc, /pester-execution-telemetry\.json/i);
  assert.match(doc, /tests:replay:local/);
  assert.match(doc, /Invoke-PesterTests\.ps1[\s\S]*operator-facing side effects directly/i);
  assert.match(doc, /durable progress telemetry/i);
  assert.match(doc, /schema versions explicitly/i);
  assert.match(doc, /unsupported-schema/i);
  assert.match(doc, /retained promotion evidence compares representative named packs/i);
  assert.match(doc, /pester-service-model-promotion-comparison\.json/i);
  assert.match(doc, /stable named entrypoints or wrappers/i);
  assert.match(doc, /retain provenance/i);
  assert.match(doc, /pester-evidence-provenance\.json/i);
  assert.match(doc, /release-evidence-provenance\.json/i);
  assert.match(doc, /promotion-dossier-provenance\.json/i);
  assert.match(doc, /classification, reason chain, and next-step context/i);
  assert.match(doc, /pester-operator-outcome\.json/i);
  assert.match(doc, /ranked requirement backlog and a selected next requirement/i);
  assert.match(doc, /preferred commands, stop conditions, and escalation conditions/i);
  assert.match(doc, /representative retained-artifact replay/i);
  assert.match(doc, /pester-windows-container-surface\.json/i);
  assert.match(doc, /Windows-container surrogate/i);
  assert.match(doc, /reachable Windows host bridge/i);
  assert.match(doc, /reopen implemented requirements when proof checks regress/i);
  assert.match(doc, /pester-service-model-next-step\.json/i);
  assert.match(doc, /machine-readable escalation step/i);
  assert.match(doc, /comparevi-local-program-next-step\.json/i);
  assert.match(doc, /shared `windows-docker-desktop-ni-image` escalations should merge/i);
  assert.match(doc, /Windows image-backed binary-handling CI surfaces/i);
  assert.match(doc, /secondary harness and evidence truth/i);
  assert.match(doc, /vi-binary-gate\.yml/i);
  assert.match(doc, /windows-ni-proof-reusable\.yml/i);
});

test('assurance packet records failure-detail producer consistency as an implemented execution requirement', () => {
  const srs = readRepoFile('docs/requirements-pester-service-model-srs.md');
  const rtm = readRepoFile('docs/rtm-pester-service-model.csv');
  const plan = readRepoFile('docs/testing/pester-service-model-test-plan.md');
  const doc = readRepoFile('docs/knowledgebase/Pester-Service-Model.md');
  const dispatcher = readRepoFile('Invoke-PesterTests.ps1');
  const finalize = readRepoFile('tools/Invoke-PesterExecutionFinalize.ps1');

  assert.match(srs, /REQ-PSM-011/);
  assert.match(srs, /explicit machine-readable unavailable-details state/i);
  assert.match(rtm, /REQ-PSM-011/);
  assert.match(rtm, /TEST-PSM-011/);
  assert.match(rtm, /PesterFailureProducerConsistency\.Tests\.ps1/);
  assert.match(rtm, /Implemented/);
  assert.match(plan, /Failure-detail producer consistency coverage/i);
  assert.match(plan, /PesterFailureProducerConsistency\.Tests\.ps1/);
  assert.match(doc, /failureDetailsStatus/i);
  assert.match(doc, /pester-failures@v2/i);
  assert.match(dispatcher, /Sync-PesterFailurePayload -Directory \$resultsDir -SummaryObject \$jsonObj/);
  assert.match(finalize, /Sync-PesterFailurePayload -Directory \$resultsDir -SummaryObject \$summaryPayloadToWrite/);
});

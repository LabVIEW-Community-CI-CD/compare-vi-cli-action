#!/usr/bin/env node

import test from 'node:test';
import assert from 'node:assert/strict';
import path from 'node:path';
import { readFileSync } from 'node:fs';

const repoRoot = process.cwd();

function readRepoFile(relativePath) {
  return readFileSync(path.join(repoRoot, relativePath), 'utf8');
}

test('reusable Windows NI proof workflow owns hosted preflight, compare, artifact upload, and optional VI-binary invariants', () => {
  const workflow = readRepoFile('.github/workflows/windows-ni-proof-reusable.yml');

  assert.match(workflow, /name:\s+Windows NI proof \(reusable\)/);
  assert.match(workflow, /workflow_call:/);
  assert.match(workflow, /run_binary_invariants:/);
  assert.match(workflow, /group:\s+\$\{\{\s*github\.workflow\s*\}\}-windows-ni-proof-\$\{\{\s*inputs\.sample_id \|\| github\.ref\s*\}\}/);
  assert.match(workflow, /runs-on:\s+windows-2022/);
  assert.match(workflow, /permissions:\s*\r?\n\s+contents:\s+read/);
  assert.match(workflow, /uses:\s+actions\/checkout@v5/);
  assert.match(
    workflow,
    /repository:\s+\$\{\{\s*github\.event_name == 'pull_request' && github\.event\.pull_request\.head\.repo\.full_name \|\| github\.repository\s*\}\}/
  );
  assert.match(
    workflow,
    /ref:\s+\$\{\{\s*github\.event_name == 'pull_request' && github\.event\.pull_request\.head\.sha \|\| github\.sha\s*\}\}/
  );
  assert.match(workflow, /Validate VI binary-handling invariants/);
  assert.match(workflow, /Test-VIBinaryHandlingInvariants\.ps1/);
  assert.match(workflow, /Prepare NI Windows image and hosted runtime/);
  assert.match(workflow, /Test-WindowsNI2026q1HostPreflight\.ps1/);
  assert.match(workflow, /-ExecutionSurface 'github-hosted-windows'/);
  assert.match(workflow, /Run NI Windows create comparison report/);
  assert.match(workflow, /Run-NIWindowsContainerCompare\.ps1/);
  assert.match(workflow, /runtime-manager-compare-windows\.json/);
  assert.match(workflow, /Validate Windows comparison report artifact contract/);
  assert.match(workflow, /vi-history\/windows-compare-artifact-summary@v1/);
  assert.match(workflow, /Upload Windows NI proof artifacts/);
  assert.match(workflow, /vi-binary-handling-invariants\.json/);
  assert.doesNotMatch(workflow, /pester-reusable\.yml/);
});

test('VI binary gate routes through the reusable Windows NI proof workflow instead of pester-reusable', () => {
  const workflow = readRepoFile('.github/workflows/vi-binary-gate.yml');

  assert.match(workflow, /name:\s+VI Binary Handling Gate/);
  assert.match(workflow, /uses:\s+\.\s*\/\.github\/workflows\/windows-ni-proof-reusable\.yml/);
  assert.match(workflow, /base_vi:\s+fixtures\/vi-stage\/control-rename\/Base\.vi/);
  assert.match(workflow, /head_vi:\s+fixtures\/vi-stage\/control-rename\/Head\.vi/);
  assert.match(workflow, /run_binary_invariants:\s+true/);
  assert.match(workflow, /results_root:\s+tests\/results\/vi-binary-gate/);
  assert.doesNotMatch(workflow, /pester-reusable\.yml/);
});

test('manual Windows hosted parity workflow reuses the same hosted Windows NI proof contract', () => {
  const workflow = readRepoFile('.github/workflows/windows-hosted-parity.yml');

  assert.match(workflow, /name:\s+Windows Hosted NI Proof \(Manual\)/);
  assert.match(workflow, /workflow_dispatch:/);
  assert.match(workflow, /uses:\s+\.\s*\/\.github\/workflows\/windows-ni-proof-reusable\.yml/);
  assert.match(workflow, /results_root:\s+tests\/results\/windows-hosted-parity/);
  assert.match(workflow, /artifact_name:\s+windows-hosted-ni-proof/);
  assert.doesNotMatch(workflow, /pester-reusable\.yml/);
});

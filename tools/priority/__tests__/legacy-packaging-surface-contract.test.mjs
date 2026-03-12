#!/usr/bin/env node

import test from 'node:test';
import assert from 'node:assert/strict';
import path from 'node:path';
import { existsSync, readFileSync, readdirSync } from 'node:fs';

const repoRoot = process.cwd();

const removedPaths = [
  '.github/workflows/vipm-provider-compare.yml',
  '.github/actions/apply-vipc',
  '.github/actions/build-lvlibp',
  '.github/actions/build-vi-package',
  '.github/actions/close-labview',
  '.github/actions/compute-version',
  '.github/actions/generate-release-notes',
  '.github/actions/missing-in-project',
  '.github/actions/modify-vipb-display-info',
  '.github/actions/rename-file',
  '.github/actions/run-unit-tests',
  '.github/actions/icon-editor',
  'configs/icon-editor',
  'docs/ICON_EDITOR_PACKAGE.md',
  'tests/IconEditorDevMode.Tests.ps1',
  'tests/IconEditorPackage.Tests.ps1',
  'tests/GCli.Provider.Tests.ps1',
  'tests/Vipm.Provider.Tests.ps1',
  'tests/Vipm.ProviderComparison.Tests.ps1',
  'tests/Vipm.ProviderTelemetry.Tests.ps1',
  'tests/fixtures/icon-editor',
  'tools/PrePush-IconEditorScope.psm1',
  'tools/GCli.psm1',
  'tools/Vipm',
  'tools/Vipm.psm1',
  'tools/icon-editor',
  'tools/providers/gcli',
  'tools/providers/vipm',
  'vendor/icon-editor',
  'fixtures/icon-editor-history',
  'issue319.html',
  'pr-576-body.md',
  'baseline-fixture-validation.json',
  'current-fixture-validation.json',
  'debug-alias.ps1',
  'debug-newparams.ps1',
  'debug-run.log',
  'debug-streaming.ps1',
  'derived-env.json',
  'final.json',
  'fixture-summary.md',
  'fixture-validation-delta.json',
  'fixture-validation-prev.json',
  'fixture-validation.json',
  'full-run.log',
  'instruction.txt',
  'issue-134.md',
  'last-run.log',
  'loop-run-summary.json',
  'loop-snapshots.ndjson',
  'outcome.log',
  'override.json',
  'single.log',
  'snippet.txt',
  'temp_patch.py',
  'temp_readme_dump.txt',
  'testResults.xml',
  'timeline.json',
  'tmp-check.py',
  'tmp-ci.yml',
  'tmp-wf.yml',
  'tmp_ci.yml',
  'issues-drafts/587-icon-editor-build-composites.md',
  'issues-drafts/588-icon-editor-composites-notes.md',
  'issues-drafts/588-icon-editor-composites-plan.md',
  'issues-drafts/588-vipm-provider-plan.md',
  'issues-drafts/589-icon-editor-build-mode.md'
];

const noVipmReferenceFiles = [
  'docs/DEVELOPER_GUIDE.md',
  'docs/TESTING_PATTERNS.md',
  'tools/Debug-ChildProcesses.ps1',
  'tools/Diagnose-LabVIEWSetup.ps1',
  'tools/Run-DX.ps1',
  'tools/VendorTools.psm1'
];

test('legacy VIPM, root icon-editor, and stale payload surfaces remain removed', () => {
  for (const relativePath of removedPaths) {
    const absolutePath = path.join(repoRoot, relativePath);
    assert.equal(existsSync(absolutePath), false, `${relativePath} should remain removed`);
  }
});

test('shared docs and helpers do not keep root VIPM references', () => {
  for (const relativePath of noVipmReferenceFiles) {
    const absolutePath = path.join(repoRoot, relativePath);
    const raw = readFileSync(absolutePath, 'utf8');
    assert.doesNotMatch(raw, /\bVIPM\b/, `${relativePath} should not mention VIPM`);
    assert.doesNotMatch(raw, /tools\/Vipm/, `${relativePath} should not point to removed tools/Vipm helpers`);
    assert.doesNotMatch(raw, /Resolve-VIPMPath/, `${relativePath} should not call the removed VIPM resolver`);
  }
});

test('stale payload filename classes stay out of the repo root and issues-drafts', () => {
  const repoEntries = readdirSync(repoRoot, { withFileTypes: true }).map((entry) => entry.name);
  const issuesDraftsPath = path.join(repoRoot, 'issues-drafts');
  const issueDraftEntries = existsSync(issuesDraftsPath)
    ? readdirSync(issuesDraftsPath, { withFileTypes: true }).map((entry) => entry.name)
    : [];

  for (const entryName of repoEntries) {
    assert.doesNotMatch(entryName, /^issue\d+\.html$/i, `${entryName} should not be a checked-in GitHub HTML dump`);
    assert.doesNotMatch(entryName, /^pr-\d+-body\.md$/i, `${entryName} should not be a checked-in PR body draft`);
  }

  for (const entryName of issueDraftEntries) {
    assert.doesNotMatch(entryName, /icon-editor|vipm/i, `${entryName} should not keep removed icon-editor or VIPM drafts`);
  }
});

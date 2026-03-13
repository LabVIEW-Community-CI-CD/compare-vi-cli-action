#!/usr/bin/env node

import test from 'node:test';
import assert from 'node:assert/strict';
import path from 'node:path';
import { existsSync, readdirSync, readFileSync } from 'node:fs';

const repoRoot = process.cwd();
const workflowsRoot = path.join(repoRoot, '.github', 'workflows');
const actionsRoot = path.join(repoRoot, '.github', 'actions');
const prHeadRepositoryPattern =
  /repository:\s+\$\{\{\s*github\.event_name == 'pull_request' && github\.event\.pull_request\.head\.repo\.full_name \|\| github\.repository\s*\}\}/;
const prHeadRefPattern =
  /ref:\s+\$\{\{\s*github\.event_name == 'pull_request' && github\.event\.pull_request\.head\.sha \|\| github\.sha\s*\}\}/;
const baseSafeRepositoryPattern = /repository:\s+\$\{\{\s*github\.repository\s*\}\}/;
const baseSafeRefPattern =
  /ref:\s+\$\{\{\s*github\.event\.pull_request\.base\.sha \|\| github\.sha\s*\}\}/;

function readText(relativePath) {
  return readFileSync(path.join(repoRoot, relativePath), 'utf8');
}

function getTopLevelTriggers(raw) {
  const lines = raw.split(/\r?\n/);
  const triggers = new Set();
  let inOnBlock = false;

  for (const line of lines) {
    if (!inOnBlock) {
      if (/^on:\s*$/.test(line)) {
        inOnBlock = true;
      }
      continue;
    }

    if (/^\S/.test(line)) {
      break;
    }

    const match = line.match(/^  ([A-Za-z_][A-Za-z0-9_-]*):/);
    if (match) {
      triggers.add(match[1]);
    }
  }

  return triggers;
}

test('PR-code workflows use explicit PR-head checkout expressions', () => {
  const workflows = [
    '.github/workflows/validate.yml',
    '.github/workflows/workflows-lint.yml',
    '.github/workflows/fixture-drift.yml',
    '.github/workflows/markdownlint.yml',
    '.github/workflows/merge-history.yml',
    '.github/workflows/commit-integrity.yml',
    '.github/workflows/dotnet-shared.yml',
    '.github/workflows/pester-integration-on-label.yml',
    '.github/workflows/promotion-contract.yml',
    '.github/workflows/code-scanning.yml'
  ];

  for (const relativePath of workflows) {
    const raw = readText(relativePath);
    assert.match(raw, /uses:\s+actions\/checkout@v5/, `${relativePath} should use actions/checkout@v5`);
    assert.match(raw, prHeadRepositoryPattern, `${relativePath} should pin checkout repository to the PR head repo`);
    assert.match(raw, prHeadRefPattern, `${relativePath} should pin checkout ref to the PR head sha`);
    assert.doesNotMatch(raw, /checkout-workflow-context/, `${relativePath} should not use the removed local checkout helper`);
  }
});

test('policy workflows keep explicit base-safe or mixed checkout expressions', () => {
  const agentReview = readText('.github/workflows/agent-review-policy.yml');
  assert.match(agentReview, /uses:\s+actions\/checkout@v5/);
  assert.match(agentReview, baseSafeRepositoryPattern);
  assert.match(agentReview, baseSafeRefPattern);
  assert.doesNotMatch(agentReview, /github\.event\.pull_request\.head\.repo\.full_name/);
  assert.doesNotMatch(agentReview, /checkout-workflow-context/);

  const policyGuard = readText('.github/workflows/policy-guard-upstream.yml');
  assert.match(policyGuard, /uses:\s+actions\/checkout@v5/);
  assert.match(policyGuard, prHeadRepositoryPattern);
  assert.match(
    policyGuard,
    /ref:\s+\$\{\{\s*github\.event_name == 'pull_request_target' && github\.event\.pull_request\.base\.sha \|\| github\.event_name == 'pull_request' && github\.event\.pull_request\.head\.sha \|\| github\.sha\s*\}\}/
  );
  assert.match(policyGuard, /fetch-depth:\s*0/);
  assert.doesNotMatch(policyGuard, /checkout-workflow-context/);
});

test('PR-capable workflows no longer depend on the removed local checkout helper', () => {
  const allowlistedExplicitRefs = new Set(['vi-compare-fork.yml']);
  const workflowFiles = readdirSync(workflowsRoot).filter((entry) => entry.endsWith('.yml'));

  for (const entry of workflowFiles) {
    const raw = readText(path.join('.github', 'workflows', entry));
    const triggers = getTopLevelTriggers(raw);
    const isPrCapable = ['pull_request', 'pull_request_target', 'merge_group']
      .some((trigger) => triggers.has(trigger));
    if (!isPrCapable) {
      continue;
    }

    assert.doesNotMatch(raw, /uses:\s+\.\/\.github\/actions\/checkout-workflow-context/, `${entry} should not use the removed local checkout helper`);

    const rawCheckouts = raw.match(/uses:\s+actions\/checkout@v[345]/g) ?? [];
    if (rawCheckouts.length === 0) {
      continue;
    }

    if (allowlistedExplicitRefs.has(entry)) {
      assert.match(raw, /ref:\s+\$\{\{\s*env\.BASE_SHA\s*\}\}/, `${entry} should keep its explicit BASE_SHA checkout`);
      continue;
    }

    assert.match(raw, /ref:\s+\$\{\{/, `${entry} should pin actions\/checkout to an explicit ref`);
  }
});

test('repo-local composite actions do not embed raw checkout or the removed helper', () => {
  const actionDirs = readdirSync(actionsRoot, { withFileTypes: true }).filter((entry) => entry.isDirectory());

  for (const entry of actionDirs) {
    const actionPath = path.join(actionsRoot, entry.name, 'action.yml');
    if (!existsSync(actionPath)) {
      continue;
    }

    const raw = readFileSync(actionPath, 'utf8');
    assert.doesNotMatch(raw, /uses:\s+actions\/checkout@v[345]/, `${entry.name} should not embed raw checkout`);
    assert.doesNotMatch(raw, /checkout-workflow-context/, `${entry.name} should not refer to the removed checkout helper`);
  }
});

test('workflow maintenance surfaces use the enclave and keep the removed checkout helper absent', () => {
  assert.equal(existsSync(path.join(repoRoot, '.github', 'actions', 'checkout-workflow-context', 'action.yml')), false);
  assert.equal(existsSync(path.join(repoRoot, 'tools', 'workflows', 'update_workflows.py')), true);
  assert.equal(existsSync(path.join(repoRoot, 'tools', 'workflows', 'workflow_enclave.py')), true);

  const hotPathFiles = [
    'AGENTS.md',
    '.github/workflows/validate.yml',
    '.github/workflows/workflows-lint.yml',
    'tools/Run-OneButtonValidate.ps1',
    'tools/Run-NonLVChecksInDocker.ps1',
    'tools/Check-WorkflowDrift.ps1'
  ];

  for (const relativePath of hotPathFiles) {
    const raw = readText(relativePath);
    assert.doesNotMatch(raw, /checkout-workflow-context/, `${relativePath} should not mention the removed checkout helper`);
    assert.doesNotMatch(raw, /pip install[^\n]*ruamel/i, `${relativePath} should not inline-install ruamel`);
  }

  const driftShim = readText('tools/Check-WorkflowDrift.ps1');
  assert.match(driftShim, /workflow_enclave\.py/, 'Check-WorkflowDrift should use the workflow enclave wrapper');
  assert.doesNotMatch(driftShim, /update_workflows\.py/, 'Check-WorkflowDrift should not call the low-level updater directly');

  const dockerShim = readText('tools/Run-NonLVChecksInDocker.ps1');
  assert.match(dockerShim, /workflow_enclave\.py/, 'Run-NonLVChecksInDocker should use the workflow enclave wrapper');

  const validateWorkflow = readText('.github/workflows/validate.yml');
  assert.match(validateWorkflow, /Check-WorkflowDrift\.ps1 -FailOnDrift/, 'Validate should enforce workflow drift through the supported entrypoint');
  assert.match(validateWorkflow, /node tools\/npm\/run-script\.mjs lint:md:changed/, 'Validate markdownlint should block on the repo-owned changed markdown surface');
  assert.doesNotMatch(validateWorkflow, /Install markdownlint-cli \(retry\)/, 'Validate should not reinstall markdownlint globally');
  assert.doesNotMatch(validateWorkflow, /Run markdownlint \(non-blocking\)/);
});

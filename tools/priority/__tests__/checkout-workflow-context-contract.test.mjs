#!/usr/bin/env node

import test from 'node:test';
import assert from 'node:assert/strict';
import path from 'node:path';
import { readdirSync, readFileSync } from 'node:fs';

const repoRoot = process.cwd();
const workflowsRoot = path.join(repoRoot, '.github', 'workflows');
const actionsRoot = path.join(repoRoot, '.github', 'actions');
const checkoutHelperUses = './.github/actions/checkout-workflow-context';

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

test('validate uses the checkout workflow context helper on PR-capable checkout steps', () => {
  const raw = readText('.github/workflows/validate.yml');

  assert.match(raw, /uses: \.\/\.github\/actions\/checkout-workflow-context/);
  assert.match(raw, /mode: 'pr-head'/);
  assert.match(raw, /fetch-depth: 0/);
  assert.doesNotMatch(raw, /actions\/checkout@v[345]/);
});

test('workflows-lint and fixture-drift use the checkout helper in pr-head mode', () => {
  const workflows = [
    '.github/workflows/workflows-lint.yml',
    '.github/workflows/fixture-drift.yml'
  ];

  for (const relativePath of workflows) {
    const raw = readText(relativePath);
    assert.match(raw, /uses: \.\/\.github\/actions\/checkout-workflow-context/);
    assert.match(raw, /mode: 'pr-head'/);
    assert.doesNotMatch(raw, /actions\/checkout@v[345]/);
  }
});

test('policy workflows keep base-safe checkout on pull_request_target paths', () => {
  const agentReview = readText('.github/workflows/agent-review-policy.yml');
  assert.match(agentReview, /uses: \.\/\.github\/actions\/checkout-workflow-context\s+with:\s+mode: 'base-safe'/);
  assert.doesNotMatch(agentReview, /actions\/checkout@v[345]/);

  const policyGuard = readText('.github/workflows/policy-guard-upstream.yml');
  assert.match(policyGuard, /uses: \.\/\.github\/actions\/checkout-workflow-context/);
  assert.match(
    policyGuard,
    /github\.event_name == 'pull_request_target' && 'base-safe' \|\| github\.event_name == 'pull_request' && 'pr-head' \|\| 'default'/
  );
  assert.match(policyGuard, /fetch-depth: 0/);
  assert.doesNotMatch(policyGuard, /actions\/checkout@v[345]/);
});

test('PR-capable workflows do not keep bare actions/checkout except the explicit vi-compare-fork base checkout', () => {
  const allowlisted = new Set(['vi-compare-fork.yml']);
  const workflowFiles = readdirSync(workflowsRoot).filter((entry) => entry.endsWith('.yml'));

  for (const entry of workflowFiles) {
    const raw = readText(path.join('.github', 'workflows', entry));
    const triggers = getTopLevelTriggers(raw);
    const isPrCapable = ['pull_request', 'pull_request_target', 'pull_request_review', 'merge_group']
      .some((trigger) => triggers.has(trigger));
    if (!isPrCapable) {
      continue;
    }

    const rawCheckouts = raw.match(/uses:\s+actions\/checkout@v[345]/g) ?? [];
    if (allowlisted.has(entry)) {
      assert.equal(rawCheckouts.length, 1, `${entry} should keep exactly one explicit raw checkout`);
      assert.match(raw, /ref:\s+\$\{\{\s*env\.BASE_SHA\s*\}\}/, `${entry} should pin the raw checkout to BASE_SHA`);
      continue;
    }

    assert.equal(rawCheckouts.length, 0, `${entry} should not contain bare actions/checkout on PR-capable paths`);
  }
});

test('repo-local composite actions no longer use raw actions/checkout directly', () => {
  const actionDirs = readdirSync(actionsRoot, { withFileTypes: true }).filter((entry) => entry.isDirectory());

  for (const entry of actionDirs) {
    const actionPath = path.join(actionsRoot, entry.name, 'action.yml');
    try {
      const raw = readFileSync(actionPath, 'utf8');
      if (entry.name === 'checkout-workflow-context') {
        assert.match(raw, /uses:\s+actions\/checkout@v5/);
        continue;
      }
      assert.doesNotMatch(raw, /uses:\s+actions\/checkout@v[345]/, `${entry.name} should not embed raw checkout`);
    } catch {
      // Ignore action directories without action.yml.
    }
  }
});

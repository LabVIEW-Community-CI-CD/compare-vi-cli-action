#!/usr/bin/env node

import test from 'node:test';
import assert from 'node:assert/strict';
import path from 'node:path';
import { readdirSync, readFileSync } from 'node:fs';

const repoRoot = process.cwd();
const githubMaintainedActionPattern =
  /uses:\s*((?:actions|github)\/[A-Za-z0-9_.-]+(?:\/[A-Za-z0-9_.-]+)?)@v(\d+)/g;
const runtimeFloorPolicy = JSON.parse(
  readFileSync(path.join(repoRoot, 'tools', 'policy', 'workflow-action-runtime-floor.json'), 'utf8')
);
const minimumMajors = new Map(
  Object.entries(runtimeFloorPolicy.actions).map(([action, policy]) => [action, policy.minimumMajor])
);

function collectWorkflowFiles(startRelativePath) {
  const startPath = path.join(repoRoot, startRelativePath);
  const queue = [startPath];
  const files = [];

  while (queue.length > 0) {
    const current = queue.pop();
    for (const entry of readdirSync(current, { withFileTypes: true })) {
      const nextPath = path.join(current, entry.name);
      if (entry.isDirectory()) {
        queue.push(nextPath);
        continue;
      }
      if (entry.name === 'action.yml' || entry.name.endsWith('.yml')) {
        files.push(path.relative(repoRoot, nextPath));
      }
    }
  }

  return files.sort();
}

test('GitHub workflow actions meet the repo Node 24 runtime floor', () => {
  const files = [
    ...collectWorkflowFiles(path.join('.github', 'workflows')),
    ...collectWorkflowFiles(path.join('.github', 'actions')),
  ];
  const failures = [];

  for (const relativePath of files) {
    const content = readFileSync(path.join(repoRoot, relativePath), 'utf8');
    for (const match of content.matchAll(githubMaintainedActionPattern)) {
      const action = match[1];
      const major = Number(match[2]);
      const minimumMajor = minimumMajors.get(action);
      if (!minimumMajor) {
        failures.push(`${relativePath}: ${action}@v${major} missing from workflow-action-runtime-floor policy`);
        continue;
      }
      if (major < minimumMajor) {
        failures.push(`${relativePath}: ${action}@v${major} < required v${minimumMajor}`);
      }
    }
  }

  assert.deepEqual(
    failures,
    [],
    `Found workflow action references below the repo Node 24 baseline:\n${failures.join('\n')}`
  );
});

test('validate workflow opts into forced Node 24 JavaScript action execution', () => {
  const validateWorkflow = readFileSync(
    path.join(repoRoot, runtimeFloorPolicy.controlledNode24ValidationWorkflow),
    'utf8'
  );

  assert.match(validateWorkflow, /FORCE_JAVASCRIPT_ACTIONS_TO_NODE24:\s*(?:'true'|"true"|true)/);
});

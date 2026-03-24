import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import test from 'node:test';

const repoRoot = path.resolve(import.meta.dirname, '..', '..', '..');

const selfHostedWorkflowPaths = [
  '.github/workflows/ci-orchestrated.yml',
  '.github/workflows/compare-artifacts.yml',
  '.github/workflows/labview-cli-compare.yml',
  '.github/workflows/pester-reusable.yml',
  '.github/workflows/runbook-validation.yml',
  '.github/workflows/smoke-on-label.yml',
  '.github/workflows/smoke.yml',
  '.github/workflows/vi-compare-pr.yml',
  '.github/workflows/vi-compare-refs.yml',
  '.github/workflows/vi-history-compare.yml',
  '.github/workflows/vi-staging-smoke.yml'
];

function readWorkflow(relativePath) {
  return fs.readFileSync(path.join(repoRoot, relativePath), 'utf8');
}

test('self-hosted compare workflows require comparevi capability ingress labels', () => {
  for (const workflowPath of selfHostedWorkflowPaths) {
    const content = readWorkflow(workflowPath);
    assert.match(
      content,
      /runs-on:\s*\[self-hosted,\s*Windows,\s*X64,\s*comparevi,\s*capability-ingress\]/,
      `${workflowPath} must route through compare capability ingress`
    );
    assert.doesNotMatch(
      content,
      /runs-on:\s*\[self-hosted,\s*Windows,\s*X64\]/,
      `${workflowPath} must not fall back to generic self-hosted Windows routing`
    );
  }
});

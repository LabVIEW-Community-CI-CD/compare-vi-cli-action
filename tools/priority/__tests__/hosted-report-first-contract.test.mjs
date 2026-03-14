import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';

const repoRoot = path.resolve(process.cwd());

function read(relativePath) {
  return fs.readFileSync(path.join(repoRoot, relativePath), 'utf8');
}

test('hosted report-first contract documents the canonical signal-workflow rules', () => {
  const doc = read('docs/HOSTED_SIGNAL_REPORT_FIRST_CONTRACT.md');
  assert.match(doc, /GH_TOKEN/);
  assert.match(doc, /GITHUB_TOKEN/);
  assert.match(doc, /report-first/i);
  assert.match(doc, /existence-aware/i);
  assert.match(doc, /issue-milestone-hygiene\.yml/);
  assert.match(doc, /downstream-onboarding-feedback\.yml/);
});

test('issue milestone hygiene and downstream onboarding implement the hosted report-first contract', () => {
  const milestoneWorkflow = read('.github/workflows/issue-milestone-hygiene.yml');
  const downstreamWorkflow = read('.github/workflows/downstream-onboarding-feedback.yml');

  assert.match(milestoneWorkflow, /GITHUB_TOKEN:\s+\$\{\{\s*secrets\.GH_TOKEN \|\| secrets\.GITHUB_TOKEN \|\| github\.token\s*\}\}/);
  assert.match(milestoneWorkflow, /GH_TOKEN:\s+\$\{\{\s*secrets\.GH_TOKEN \|\| secrets\.GITHUB_TOKEN \|\| github\.token\s*\}\}/);
  assert.match(milestoneWorkflow, /Append summary/);
  assert.match(milestoneWorkflow, /if-no-files-found:\s+error/);

  assert.match(downstreamWorkflow, /GITHUB_TOKEN:\s*\$\{\{\s*github\.token\s*\}\}/);
  assert.match(downstreamWorkflow, /GH_TOKEN:\s*\$\{\{\s*github\.token\s*\}\}/);
  assert.match(downstreamWorkflow, /Append onboarding feedback summary/);
  assert.match(
    downstreamWorkflow,
    /if:\s+\$\{\{\s*always\(\)\s*&&\s*hashFiles\('tests\/results\/_agent\/onboarding\/\*\.json'\)\s*!=\s*''\s*\}\}/
  );
  assert.match(downstreamWorkflow, /if-no-files-found:\s+error/);
});

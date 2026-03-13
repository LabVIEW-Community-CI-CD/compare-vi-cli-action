#!/usr/bin/env node

import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import path from 'node:path';

const repoRoot = process.cwd();

function readRepoFile(relativePath) {
  return readFileSync(path.join(repoRoot, relativePath), 'utf8');
}

test('issue milestone hygiene workflow has deterministic trigger and artifact contract', () => {
  const workflow = readRepoFile('.github/workflows/issue-milestone-hygiene.yml');

  assert.match(workflow, /name:\s+Issue Milestone Hygiene/);
  assert.match(workflow, /issues:\s*\n\s*types:/);
  assert.match(workflow, /-\s*milestoned/);
  assert.match(workflow, /-\s*demilestoned/);
  assert.match(workflow, /schedule:\s*\n\s*-\s*cron:\s*'25 \* \* \* \*'/);
  assert.match(workflow, /workflow_dispatch:/);
  assert.match(workflow, /concurrency:\s*\n\s*group:\s+\$\{\{\s*github\.workflow\s*\}\}-\$\{\{\s*github\.event_name\s*\}\}-\$\{\{\s*github\.event\.issue\.number \|\| github\.ref \|\| github\.run_id\s*\}\}/);
  assert.match(workflow, /cancel-in-progress:\s+true/);

  assert.match(workflow, /apply_default_milestone:/);
  assert.match(workflow, /create_default_milestone:/);
  assert.match(workflow, /default_milestone:/);
  assert.match(workflow, /default_milestone_due_on:/);
  assert.match(workflow, /warn_only:/);

  assert.match(workflow, /issues:\s*write/);
  assert.match(workflow, /GITHUB_TOKEN:\s+\$\{\{\s*secrets\.GH_TOKEN \|\| secrets\.GITHUB_TOKEN \|\| github\.token\s*\}\}/);
  assert.match(workflow, /GH_TOKEN:\s+\$\{\{\s*secrets\.GH_TOKEN \|\| secrets\.GITHUB_TOKEN \|\| github\.token\s*\}\}/);
  assert.match(workflow, /priority:milestone:hygiene/);
  assert.match(workflow, /--create-default-milestone/);
  assert.match(workflow, /--default-milestone-due-on/);
  assert.match(workflow, /tests\/results\/_agent\/issue\/milestone-hygiene-report\.json/);
  assert.match(workflow, /execution status/);
  assert.match(workflow, /uses:\s+actions\/upload-artifact@v6/);
  assert.match(workflow, /if-no-files-found:\s+error/);
});

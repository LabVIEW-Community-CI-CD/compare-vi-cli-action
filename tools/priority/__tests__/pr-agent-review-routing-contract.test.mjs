#!/usr/bin/env node

import test from 'node:test';
import assert from 'node:assert/strict';
import path from 'node:path';
import { readFileSync } from 'node:fs';

const repoRoot = process.cwd();

test('pr-agent-review-routing defaults agent-authored reviewer routing to Copilot', () => {
  const workflow = readFileSync(
    path.join(repoRoot, '.github', 'workflows', 'pr-agent-review-routing.yml'),
    'utf8'
  );

  assert.match(workflow, /REQUIRED_AGENT_REVIEWER:\s+\$\{\{\s*vars\.REQUIRED_AGENT_REVIEWER \|\| 'Copilot'\s*\}\}/);
  assert.doesNotMatch(workflow, /github\.repository_owner/);
  assert.match(workflow, /const requiredReviewer = \(process\.env\.REQUIRED_AGENT_REVIEWER \|\| 'Copilot'\)\.trim\(\);/);
  assert.match(workflow, /reviewers:\s+\[requiredReviewer\]/);
});

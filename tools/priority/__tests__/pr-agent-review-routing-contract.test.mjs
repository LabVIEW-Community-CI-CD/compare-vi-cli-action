#!/usr/bin/env node

import test from 'node:test';
import assert from 'node:assert/strict';
import path from 'node:path';
import { readFileSync } from 'node:fs';

const repoRoot = process.cwd();

test('pr-agent-review-routing keeps draft-phase routing local-only for agent-authored PRs', () => {
  const workflow = readFileSync(
    path.join(repoRoot, '.github', 'workflows', 'pr-agent-review-routing.yml'),
    'utf8'
  );

  assert.match(
    workflow,
    /pull_request_target:\s+types:\s+\[opened, synchronize, reopened, edited, labeled, unlabeled, converted_to_draft\]/
  );
  assert.doesNotMatch(workflow, /ready_for_review/);
  assert.match(workflow, /jobs:\s+request-reviewer:\s+if: github\.event\.pull_request\.draft == true/ms);
  assert.doesNotMatch(workflow, /github\.repository_owner/);
  assert.doesNotMatch(workflow, /REQUIRED_AGENT_REVIEWER/);
  assert.doesNotMatch(workflow, /requestReviewers/);
  assert.match(
    workflow,
    /GitHub-side Copilot reviewer routing is disabled for this repository;[\s\S]*draft-review acquisition remains local-only/
  );
});

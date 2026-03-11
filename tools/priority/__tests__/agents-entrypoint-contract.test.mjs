#!/usr/bin/env node

import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..', '..');

function readText(relativePath) {
  return readFileSync(path.join(repoRoot, relativePath), 'utf8');
}

test('AGENTS stays bounded and points future sessions at helper surfaces instead of inline runbooks', () => {
  const agents = readText('AGENTS.md');
  const lines = agents.trimEnd().split(/\r?\n/);

  assert.ok(lines.length <= 120, `Expected AGENTS.md to stay within 120 lines, found ${lines.length}.`);
  assert.equal(lines[1], '# Agent Handbook');
  assert.match(agents, /bounded agent entrypoint/i);
  assert.match(agents, /queue-empty/i);
  assert.match(agents, /priority:delivery:agent:ensure/);
  assert.match(agents, /priority:codex:state:hygiene:apply/);
  assert.match(agents, /handoff:entrypoint:check/);
  assert.match(agents, /priority:handoff/);
  assert.match(agents, /machine-readable index/i);
  assert.match(agents, /New-IssueBody\.ps1/);
  assert.match(agents, /New-GitHubIntakeDraft\.ps1/);
  assert.match(agents, /Invoke-GitHubIntakeScenario\.ps1/);
  assert.match(agents, /Write-GitHubIntakeAtlas\.ps1/);
  assert.match(agents, /Resolve-GitHubIntakeRoute\.ps1/);
  assert.match(agents, /GitHub wiki as a curated portal only/i);
  assert.match(agents, /-PRTemplate workflow-policy\|human-change/);
});

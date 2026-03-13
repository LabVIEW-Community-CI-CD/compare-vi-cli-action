#!/usr/bin/env node

import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..', '..');

test('pre-commit hook invokes the repo-owned Copilot CLI review wrapper for staged diffs', () => {
  const source = readFileSync(path.join(repoRoot, 'tools', 'hooks', 'core', 'pre-commit.mjs'), 'utf8');
  assert.match(source, /copilot-cli-review\.mjs/);
  assert.match(source, /['"]copilot-cli-review['"]/);
  assert.match(source, /['"]pre-commit['"]/);
});

test('pre-push checks invoke the repo-owned Copilot CLI review wrapper as the final local review gate', () => {
  const source = readFileSync(path.join(repoRoot, 'tools', 'PrePush-Checks.ps1'), 'utf8');
  assert.match(source, /Invoke-CopilotCliReviewGate/);
  assert.match(source, /copilot-cli-review\.mjs/);
  assert.match(source, /--profile pre-push/);
});

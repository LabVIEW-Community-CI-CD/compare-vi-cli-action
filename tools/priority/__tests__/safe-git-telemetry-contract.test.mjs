#!/usr/bin/env node

import test from 'node:test';
import assert from 'node:assert/strict';
import path from 'node:path';
import { readFileSync } from 'node:fs';

const repoRoot = process.cwd();

function readRepoFile(relativePath) {
  return readFileSync(path.join(repoRoot, relativePath), 'utf8');
}

test('branch-utils routes mutating git calls through safe-git telemetry path', () => {
  const content = readRepoFile('tools/priority/lib/branch-utils.mjs');
  assert.match(content, /resolveSafeGitTelemetryPath/);
  assert.match(content, /telemetryPath:\s*resolveSafeGitTelemetryPath/);
});

test('run-handoff-tests routes mutating git calls through safe-git telemetry path', () => {
  const content = readRepoFile('tools/priority/run-handoff-tests.mjs');
  assert.match(content, /safeGitTelemetryPath/);
  assert.match(content, /telemetryPath:\s*safeGitTelemetryPath/);
});

test('pre-push checks summarize safe-git reliability telemetry', () => {
  const content = readRepoFile('tools/PrePush-Checks.ps1');
  assert.match(content, /Invoke-SafeGitReliabilitySummary/);
  assert.match(content, /summarize-safe-git-telemetry\.mjs/);
  assert.match(content, /safe-git-trend-summary\.json/);
});

test('bootstrap summarizes safe-git reliability telemetry', () => {
  const content = readRepoFile('tools/priority/bootstrap.ps1');
  assert.match(content, /Invoke-SafeGitReliabilitySummary/);
  assert.match(content, /summarize-safe-git-telemetry\.mjs/);
  assert.match(content, /safe-git-trend-summary\.json/);
});


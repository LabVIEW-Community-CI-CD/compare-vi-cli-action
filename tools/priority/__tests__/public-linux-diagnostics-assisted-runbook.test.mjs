#!/usr/bin/env node

import test from 'node:test';
import assert from 'node:assert/strict';
import path from 'node:path';
import { readFileSync } from 'node:fs';

const repoRoot = process.cwd();

function readRepoFile(relativePath) {
  return readFileSync(path.join(repoRoot, relativePath), 'utf8');
}

test('public Linux assisted runbook points operators to the local, hosted, review, and human decision surfaces', () => {
  const doc = readRepoFile('docs/PUBLIC_LINUX_DIAGNOSTICS_ASSISTED_RUNBOOK.md');

  assert.match(doc, /Run-NonLVChecksInDocker\.ps1 -UseToolsImage -NILinuxReviewSuite/);
  assert.match(doc, /public-linux-diagnostics-harness\.yml/);
  assert.match(doc, /public-linux-diagnostics-workflow-dispatch\.json/);
  assert.match(doc, /review-loop-receipt\.json/);
  assert.match(doc, /docker-review-loop-summary\.json/);
  assert.match(doc, /human-go-no-go-feedback\.yml/);
  assert.match(doc, /human-go-no-go-decision\.json/);
});

test('public Linux assisted runbook records the preferred consolidated review renderer path', () => {
  const doc = readRepoFile('docs/PUBLIC_LINUX_DIAGNOSTICS_ASSISTED_RUNBOOK.md');

  assert.match(doc, /public-linux-diagnostics-review-summary\.mjs/);
  assert.match(doc, /public-linux-diagnostics-review-summary\.json/);
  assert.match(doc, /public-linux-diagnostics-review-summary\.md/);
  assert.match(doc, /When the consolidated renderer is available on the current branch/i);
});

test('public Linux assisted runbook keeps the human operator as the final disposition authority', () => {
  const doc = readRepoFile('docs/PUBLIC_LINUX_DIAGNOSTICS_ASSISTED_RUNBOOK.md');

  assert.match(doc, /The operator must:/);
  assert.match(doc, /give the final go\/no-go/i);
  assert.match(doc, /Machine success without the human decision is not session completion/i);
});

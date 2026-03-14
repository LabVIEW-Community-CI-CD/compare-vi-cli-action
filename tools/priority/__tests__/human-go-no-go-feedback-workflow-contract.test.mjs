#!/usr/bin/env node

import test from 'node:test';
import assert from 'node:assert/strict';
import path from 'node:path';
import { readFileSync } from 'node:fs';

const repoRoot = process.cwd();

function readRepoFile(relativePath) {
  return readFileSync(path.join(repoRoot, relativePath), 'utf8');
}

test('human go/no-go workflow is workflow_dispatch-only and exposes the manual decision inputs', () => {
  const workflow = readRepoFile('.github/workflows/human-go-no-go-feedback.yml');

  assert.match(workflow, /^on:\s*\r?\n\s+workflow_dispatch:/m);
  assert.doesNotMatch(workflow, /^\s*pull_request:/m);
  assert.doesNotMatch(workflow, /^\s*pull_request_target:/m);
  assert.match(workflow, /decision:\s+\s*description:[\s\S]+type: choice[\s\S]+options:\s+\s+- go\s+\s+- nogo/m);
  assert.match(workflow, /feedback:\s+\s*description:[\s\S]+required: true[\s\S]+type: string/m);
  assert.match(workflow, /recommended_action:[\s\S]+options:\s+\s+- continue\s+\s+- revise\s+\s+- pause/m);
});

test('human go/no-go workflow writes and uploads deterministic handoff artifacts', () => {
  const workflow = readRepoFile('.github/workflows/human-go-no-go-feedback.yml');

  assert.match(workflow, /tools\/priority\/human-go-no-go-feedback\.mjs/);
  assert.match(workflow, /--decision-out" "tests\/results\/_agent\/handoff\/human-go-no-go-decision\.json"/);
  assert.match(workflow, /--events-out" "tests\/results\/_agent\/handoff\/human-go-no-go-events\.ndjson"/);
  assert.match(workflow, /--step-summary" "\$GITHUB_STEP_SUMMARY"/);
  assert.match(workflow, /name: Upload manual go\/no-go artifacts\s+if: always\(\)\s+uses: actions\/upload-artifact@v6/);
  assert.match(workflow, /name: human-go-no-go-decision/);
});

test('human go/no-go workflow keeps token permissions minimal', () => {
  const workflow = readRepoFile('.github/workflows/human-go-no-go-feedback.yml');

  assert.match(workflow, /permissions:\s+contents: read/ms);
  assert.doesNotMatch(workflow, /permissions:\s+write-all/);
  assert.doesNotMatch(workflow, /deployments:\s+write/);
  assert.doesNotMatch(workflow, /pull-requests:\s+write/);
});

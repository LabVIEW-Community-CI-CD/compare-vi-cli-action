#!/usr/bin/env node

import test from 'node:test';
import assert from 'node:assert/strict';
import path from 'node:path';
import { readFileSync } from 'node:fs';

const repoRoot = process.cwd();

function readRepoFile(relativePath) {
  return readFileSync(path.join(repoRoot, relativePath), 'utf8');
}

test('pester service-model release-evidence workflow retains hosted promotion evidence without fork-only runtime dependencies', () => {
  const workflow = readRepoFile('.github/workflows/pester-service-model-release-evidence.yml');

  assert.match(workflow, /name:\s+Pester service-model release evidence/);
  assert.match(workflow, /workflow_dispatch:/);
  assert.match(workflow, /pull_request:/);
  assert.match(workflow, /PSM_FORK_BASIS_COMMIT/);
  assert.match(workflow, /PSM_FORK_BASIS_URL/);
  assert.match(workflow, /name:\s+Release evidence \/ pester-service-model/);
  assert.match(workflow, /write-node-test-coverage-xml\.mjs/);
  assert.match(workflow, /coverage\.xml/);
  assert.match(workflow, /Docs link check \/ lychee/);
  assert.doesNotMatch(workflow, /fork-lane-local-assurance-ci\.mjs/);
  assert.match(workflow, /pester-service-model-provenance\.mjs/);
  assert.match(workflow, /pester-service-model-promotion-comparison\.json/);
  assert.match(workflow, /pester-promotion-comparison-v1\.schema\.json/);
  assert.match(workflow, /pester-service-model-release-evidence-provenance\.test\.mjs/);
  assert.match(workflow, /materialize-pester-service-model-release-evidence\.mjs/);
  assert.match(workflow, /render-pester-service-model-promotion-dossier\.mjs/);
  assert.match(workflow, /release-evidence-provenance\.json/);
  assert.match(workflow, /promotion-dossier-provenance\.json/);
  assert.match(workflow, /Upload release-evidence bundle/);
});

#!/usr/bin/env node

import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { execFileSync } from 'node:child_process';

const repoRoot = process.cwd();

function runNode(scriptRelativePath, args, extraEnv = {}) {
  return execFileSync(
    process.execPath,
    [path.join(repoRoot, scriptRelativePath), ...args],
    {
      cwd: repoRoot,
      encoding: 'utf8',
      env: {
        ...process.env,
        GITHUB_REPOSITORY: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
        GITHUB_WORKFLOW: 'Pester service-model release evidence',
        GITHUB_EVENT_NAME: 'workflow_dispatch',
        GITHUB_RUN_ID: '1234567890',
        GITHUB_RUN_ATTEMPT: '2',
        GITHUB_REF: 'refs/heads/integration/pester-service-model',
        GITHUB_REF_NAME: 'integration/pester-service-model',
        GITHUB_SHA: '0123456789abcdef0123456789abcdef01234567',
        GITHUB_SERVER_URL: 'https://github.com',
        ...extraEnv
      }
    }
  );
}

test('release evidence materializer emits provenance for retained hosted inputs and bundle outputs', async (t) => {
  const tempRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'psm-release-evidence-'));
  t.after(() => fs.rmSync(tempRoot, { recursive: true, force: true }));

  const baseDir = path.join(tempRoot, 'base');
  const outputDir = path.join(tempRoot, 'bundle');
  fs.mkdirSync(baseDir, { recursive: true });
  fs.writeFileSync(path.join(baseDir, 'coverage.xml'), '<coverage />\n', 'utf8');
  fs.writeFileSync(path.join(baseDir, 'docs-link-check.json'), '{"links":[]}\n', 'utf8');

  runNode(
    'tools/priority/materialize-pester-service-model-release-evidence.mjs',
    [
      '--repo-root', repoRoot,
      '--base-dir', baseDir,
      '--output-dir', outputDir,
      '--version', 'v9.9.9',
      '--upstream-issue', '2069',
      '--fork-issue', '2078',
      '--fork-basis-commit', 'deadbeef',
      '--fork-basis-url', 'https://example.test/fork-basis'
    ]
  );

  const provenancePath = path.join(outputDir, 'release-evidence-provenance.json');
  assert.ok(fs.existsSync(provenancePath));
  const provenance = JSON.parse(fs.readFileSync(provenancePath, 'utf8'));
  assert.equal(provenance.schema, 'pester-derived-provenance@v1');
  assert.equal(provenance.provenanceKind, 'release-evidence');
  assert.equal(provenance.subject.baselineVersion, 'v9.9.9');
  assert.equal(provenance.runContext.runId, '1234567890');
  assert.equal(provenance.runContext.refName, 'integration/pester-service-model');
  assert.ok(provenance.sourceInputs.some((entry) => entry.role === 'coverage-xml' && entry.present));
  assert.ok(provenance.sourceInputs.some((entry) => entry.role === 'docs-link-check' && entry.present));
  assert.ok(provenance.sourceInputs.some((entry) => entry.role === 'promotion-comparison' && entry.present));
  assert.ok(provenance.derivedOutputs.some((entry) => entry.role === 'release-record' && entry.present));
  assert.ok(provenance.derivedOutputs.some((entry) => entry.role === 'requirements-srs' && entry.present));
  assert.ok(fs.existsSync(path.join(outputDir, 'pester-service-model-promotion-comparison.json')));
});

test('promotion dossier render emits provenance that points back to the release-evidence bundle', async (t) => {
  const tempRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'psm-promotion-dossier-'));
  t.after(() => fs.rmSync(tempRoot, { recursive: true, force: true }));

  const baseDir = path.join(tempRoot, 'base');
  const outputDir = path.join(tempRoot, 'bundle');
  fs.mkdirSync(baseDir, { recursive: true });
  fs.writeFileSync(path.join(baseDir, 'coverage.xml'), '<coverage />\n', 'utf8');
  fs.writeFileSync(path.join(baseDir, 'docs-link-check.json'), '{"links":[]}\n', 'utf8');

  runNode(
    'tools/priority/materialize-pester-service-model-release-evidence.mjs',
    [
      '--repo-root', repoRoot,
      '--base-dir', baseDir,
      '--output-dir', outputDir,
      '--version', 'v9.9.9'
    ]
  );
  runNode(
    'tools/priority/render-pester-service-model-promotion-dossier.mjs',
    [
      '--repo-root', repoRoot,
      '--release-evidence-dir', outputDir,
      '--upstream-issue', '2069',
      '--fork-issue', '2078'
    ]
  );

  const provenancePath = path.join(outputDir, 'promotion-dossier-provenance.json');
  const dossierPath = path.join(outputDir, 'promotion-dossier.md');
  assert.ok(fs.existsSync(dossierPath));
  assert.ok(fs.existsSync(provenancePath));
  const provenance = JSON.parse(fs.readFileSync(provenancePath, 'utf8'));
  assert.equal(provenance.schema, 'pester-derived-provenance@v1');
  assert.equal(provenance.provenanceKind, 'promotion-dossier');
  const dossier = fs.readFileSync(dossierPath, 'utf8');
  assert.match(dossier, /Representative Pack Comparisons/);
  assert.match(dossier, /dispatcher-first-slice-baseline-vs-service-model/);
  assert.match(dossier, /23818978524/);
  assert.match(dossier, /23795198442/);
  assert.ok(provenance.sourceInputs.some((entry) => entry.role === 'release-evidence-provenance' && entry.present));
  assert.ok(provenance.sourceInputs.some((entry) => entry.role === 'promotion-comparison' && entry.present));
  assert.ok(provenance.derivedOutputs.some((entry) => entry.role === 'promotion-dossier' && entry.present));
});

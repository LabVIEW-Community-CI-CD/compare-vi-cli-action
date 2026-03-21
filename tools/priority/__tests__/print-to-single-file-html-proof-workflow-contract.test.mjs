import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..', '..');

test('PrintToSingleFileHtml proof workflow is dispatch-only and target-driven', async () => {
  const workflow = await readFile(
    path.join(repoRoot, '.github', 'workflows', 'print-to-single-file-html-proof.yml'),
    'utf8'
  );

  assert.match(workflow, /^on:\s*\r?\n\s+workflow_dispatch:/m);
  assert.match(workflow, /target_id:/);
  assert.doesNotMatch(workflow, /^\s+pull_request:/m);
  assert.doesNotMatch(workflow, /^\s+push:/m);
});

test('PrintToSingleFileHtml proof workflow runs the wrapper and uploads proof artifacts', async () => {
  const workflow = await readFile(
    path.join(repoRoot, '.github', 'workflows', 'print-to-single-file-html-proof.yml'),
    'utf8'
  );

  assert.match(workflow, /Invoke-HeadlessSampleVICorpusPrintProof\.ps1/);
  assert.match(workflow, /actions\/upload-artifact@v7/);
  assert.match(workflow, /name: print-to-single-file-html-proof/);
  assert.match(workflow, /tests\/results\/_agent\/headless-sample-corpus\/print-proof\/\*\.json/);
  assert.match(workflow, /tests\/results\/_agent\/headless-sample-corpus\/print-proof\/\*\.md/);
});

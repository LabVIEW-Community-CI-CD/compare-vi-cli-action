import assert from 'node:assert/strict';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath, pathToFileURL } from 'node:url';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..', '..');
const modulePath = path.join(repoRoot, 'tools', 'priority', 'download-run-artifact.mjs');

let modulePromise = null;

async function loadModule() {
  if (!modulePromise) {
    modulePromise = import(`${pathToFileURL(modulePath).href}?cache=${Date.now()}`);
  }
  return modulePromise;
}

test('parseArgs accepts --all for whole-run downloads', async () => {
  const { parseArgs } = await loadModule();
  const options = parseArgs([
    'node',
    'download-run-artifact.mjs',
    '--repo',
    'LabVIEW-Community-CI-CD/compare-vi-cli-action',
    '--run-id',
    '23031304891',
    '--all',
  ]);

  assert.equal(options.repo, 'LabVIEW-Community-CI-CD/compare-vi-cli-action');
  assert.equal(options.runId, '23031304891');
  assert.equal(options.all, true);
  assert.deepEqual(options.artifactNames, []);
});

test('parseArgs rejects mixing --all with explicit artifact names', async () => {
  const { parseArgs } = await loadModule();
  assert.throws(
    () =>
      parseArgs([
        'node',
        'download-run-artifact.mjs',
        '--repo',
        'LabVIEW-Community-CI-CD/compare-vi-cli-action',
        '--run-id',
        '23031304891',
        '--all',
        '--artifact',
        'compare-changed-vis',
      ]),
    /either --all or one or more --artifact values/i,
  );
});

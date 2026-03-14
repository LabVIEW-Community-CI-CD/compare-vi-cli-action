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

test('parseArgs accepts --all without requiring named artifacts', async () => {
  const { parseArgs } = await loadModule();
  const parsed = parseArgs([
    'node',
    'download-run-artifact.mjs',
    '--repo',
    'LabVIEW-Community-CI-CD/compare-vi-cli-action',
    '--run-id',
    '12345',
    '--all',
  ]);

  assert.equal(parsed.repo, 'LabVIEW-Community-CI-CD/compare-vi-cli-action');
  assert.equal(parsed.runId, '12345');
  assert.equal(parsed.downloadAll, true);
  assert.deepEqual(parsed.artifactNames, []);
});

test('parseArgs rejects mixing --all with named artifacts', async () => {
  const { parseArgs } = await loadModule();
  assert.throws(
    () =>
      parseArgs([
        'node',
        'download-run-artifact.mjs',
        '--repo',
        'LabVIEW-Community-CI-CD/compare-vi-cli-action',
        '--run-id',
        '12345',
        '--all',
        '--artifact',
        'artifact-a',
      ]),
    /Use either --all or one or more --artifact values, not both\./,
  );
});

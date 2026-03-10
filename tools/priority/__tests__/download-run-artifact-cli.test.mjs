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

test('parseArgs trims artifact names and rejects whitespace-only values', async () => {
  const { parseArgs } = await loadModule();

  const parsed = parseArgs([
    'node',
    'tools/priority/download-run-artifact.mjs',
    '--repo',
    'LabVIEW-Community-CI-CD/compare-vi-cli-action',
    '--run-id',
    '22872590273',
    '--artifact',
    '  copilot-review-signal-975  ',
  ]);

  assert.deepEqual(parsed.artifactNames, ['copilot-review-signal-975']);
  assert.throws(
    () =>
      parseArgs([
        'node',
        'tools/priority/download-run-artifact.mjs',
        '--repo',
        'LabVIEW-Community-CI-CD/compare-vi-cli-action',
        '--run-id',
        '22872590273',
        '--artifact',
        '   ',
      ]),
    /Artifact name is required/,
  );
});

test('isDirectExecution accepts the documented relative script invocation', async () => {
  const { isDirectExecution } = await loadModule();
  const relativeModulePath = path.relative(process.cwd(), modulePath);

  assert.equal(isDirectExecution(['node', relativeModulePath], pathToFileURL(modulePath).href), true);
  assert.equal(isDirectExecution(['node', 'tools/priority/other-script.mjs'], pathToFileURL(modulePath).href), false);
});

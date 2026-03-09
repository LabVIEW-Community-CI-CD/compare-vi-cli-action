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

test('isDirectExecution matches the current module path without file URL reconstruction drift', async () => {
  const { isDirectExecution } = await loadModule();

  assert.equal(isDirectExecution(['node', modulePath], pathToFileURL(modulePath).href), true);
  assert.equal(isDirectExecution(['node', path.join(repoRoot, 'tools', 'priority', 'other-file.mjs')], pathToFileURL(modulePath).href), false);
});

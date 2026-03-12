import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath, pathToFileURL } from 'node:url';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..', '..');
const distModulePath = path.join(repoRoot, 'dist', 'tools', 'priority', 'delivery-agent.js');

let builtModulePromise = null;

async function loadModule() {
  if (!builtModulePromise) {
    const buildResult = spawnSync(process.execPath, ['tools/npm/run-script.mjs', 'build'], {
      cwd: repoRoot,
      encoding: 'utf8',
    });
    assert.equal(buildResult.status, 0, [buildResult.stdout, buildResult.stderr].filter(Boolean).join('\n'));
    builtModulePromise = import(`${pathToFileURL(distModulePath).href}?cache=${Date.now()}`);
  }
  return builtModulePromise;
}

test('delivery-agent CLI parses ensure and prereq subcommands through the TS entrypoint', async () => {
  const { parseArgs } = await loadModule();

  assert.deepEqual(parseArgs(['node', 'delivery-agent.js', 'ensure', '--sleep-mode', '--wsl-distro', 'Ubuntu']).command, 'ensure');
  assert.equal(parseArgs(['node', 'delivery-agent.js', 'ensure', '--sleep-mode']).sleepMode, true);
  assert.equal(parseArgs(['node', 'delivery-agent.js', 'prereqs', '--node-version', 'v24.13.1']).command, 'prereqs');
  assert.equal(parseArgs(['node', 'delivery-agent.js', 'status']).command, 'status');
  assert.equal(parseArgs(['node', 'delivery-agent.js', 'run', '--runtime-dir', 'tests/results/_agent/runtime']).runtimeDir, 'tests/results/_agent/runtime');
});

import assert from 'node:assert/strict';
import path from 'node:path';
import test from 'node:test';
import { spawnSync } from 'node:child_process';
import { pathToFileURL, fileURLToPath } from 'node:url';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..', '..');
const distModulePath = path.join(repoRoot, 'dist', 'tools', 'priority', 'lib', 'delivery-agent-manager.js');

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

test('resolvePostRepairHostConflict routes runner-conflict after a successful native daemon repair', async () => {
  const { resolvePostRepairHostConflict } = await loadModule();

  const resolution = resolvePostRepairHostConflict({
    repairedHostSignal: {
      status: 'native-wsl',
      provider: 'native-wsl',
      daemonFingerprint: '262de6f1',
    },
    collectedHostSignal: {
      status: 'runner-conflict',
      provider: 'native-wsl',
      daemonFingerprint: '262de6f1',
    },
  });

  assert.equal(resolution.status, 'routed-runner-conflict');
  assert.equal(resolution.blockedByHostConflict, false);
  assert.equal(resolution.effectiveHostSignal.status, 'native-wsl');
  assert.equal(resolution.reason, 'native-daemon-repair-succeeded-runner-services-remain-observed');
});

test('resolvePostRepairHostConflict stays blocked when the post-repair host state is still non-native', async () => {
  const { resolvePostRepairHostConflict } = await loadModule();

  const resolution = resolvePostRepairHostConflict({
    repairedHostSignal: {
      status: 'native-wsl',
      provider: 'native-wsl',
      daemonFingerprint: '262de6f1',
    },
    collectedHostSignal: {
      status: 'desktop-backed',
      provider: 'desktop',
      daemonFingerprint: '262de6f1',
    },
  });

  assert.equal(resolution.status, 'blocked');
  assert.equal(resolution.blockedByHostConflict, true);
  assert.equal(resolution.effectiveHostSignal.status, 'desktop-backed');
  assert.equal(resolution.reason, 'post-repair-conflict-persisted');
});

import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = dirname(fileURLToPath(import.meta.url));
const repoRoot = join(__dirname, '..', '..', '..');

const EXPECTED = {
  customActions: {
    'VIP_Pre-Install Custom Action 2021.vi': '05ddb5a2995124712e31651ed4a623e0e43044435ff7af62c24a65fbe2a5273a',
    'VIP_Post-Install Custom Action 2021.vi': '29b4aec05c38707975a4d6447daab8eea6c59fcf0cde45f899f8807b11cd475e',
    'VIP_Pre-Uninstall Custom Action 2021.vi': 'a10234da4dfe23b87f6e7a25f3f74ae30751193928d5700a628593f1120a5a91',
    'VIP_Post-Uninstall Custom Action 2021.vi': '958b253a321fec8e65805195b1e52cda2fd509823d0ad18b29ae341513d4615b',
  },
  artifacts: {
    'lv_icon_x64.lvlibp': 'e851ac8d296e78f4ed1fd66af576c50ae5ff48caf18775ac3d4085c29d4bd013',
    'lv_icon_x86.lvlibp': '8a3d07791c5f03d11bddfb32d25fd5d7c933a2950d96b5668cc5837fe7dece23',
  },
  runnerDependencies: '3b279b60d8cd0d9a9f5f6ce00c6dad1e68595cd14d22b13323f9f264cdf59ac6',
};

function loadReport() {
  const reportPath = join(repoRoot, 'tests', 'results', '_agent', 'icon-editor', 'fixture-report.json');
  const data = readFileSync(reportPath, 'utf8');
  return JSON.parse(data);
}

test('custom action hashes match expectations', () => {
  const summary = loadReport();
  const actual = Object.fromEntries(summary.customActions.map((entry) => [entry.name, entry.fixture?.hash ?? null]));

  assert.deepEqual(actual, EXPECTED.customActions);
});

test('artifact hashes match expectations', () => {
  const summary = loadReport();
  const actual = Object.fromEntries(summary.artifacts
    .filter((artifact) => EXPECTED.artifacts[artifact.name])
    .map((artifact) => [artifact.name, artifact.hash]));

  assert.deepEqual(actual, EXPECTED.artifacts);
});

test('runner dependencies hash matches expectation', () => {
  const summary = loadReport();
  assert.equal(summary.runnerDependencies.fixture.hash, EXPECTED.runnerDependencies);
});

test('stakeholder snapshot provides summary metadata', () => {
  const summary = loadReport();
  const stakeholder = summary.stakeholder;

  assert.ok(stakeholder, 'stakeholder summary missing');
  assert.equal(stakeholder.version, '1.4.1.948');
  assert.equal(stakeholder.systemVersion, '1.4.1.948');
  assert.equal(stakeholder.license, 'MIT');
  assert.equal(stakeholder.smokeStatus, 'ok');
  assert.equal(stakeholder.simulationEnabled, true);
  assert.equal(stakeholder.runnerDependencies.hash, EXPECTED.runnerDependencies);
  assert.equal(stakeholder.runnerDependencies.matchesRepo, true);

  const stakeholderArtifactHashes = Object.fromEntries(stakeholder.artifacts.map((artifact) => [artifact.name, artifact.hash]));
  for (const [name, hash] of Object.entries(EXPECTED.artifacts)) {
    assert.equal(stakeholderArtifactHashes[name], hash);
  }

  const stakeholderCustomActionHashes = Object.fromEntries(stakeholder.customActions.map((action) => [action.name, action.hash]));
  for (const [name, hash] of Object.entries(EXPECTED.customActions)) {
    assert.equal(stakeholderCustomActionHashes[name], hash);
  }

  assert.ok(Array.isArray(stakeholder.fixtureOnlyAssets));
  assert.ok(stakeholder.fixtureOnlyAssets.length > 0);
  assert.ok(typeof stakeholder.generatedAt === 'string' && stakeholder.generatedAt.length > 0);
});

import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = dirname(fileURLToPath(import.meta.url));
const repoRoot = join(__dirname, '..', '..', '..');

function loadReport() {
  const reportPath = join(repoRoot, 'tests', 'results', '_agent', 'icon-editor', 'fixture-report.json');
  const data = readFileSync(reportPath, 'utf8');
  return JSON.parse(data);
}

function loadBaseline() {
  const basePath = join(repoRoot, 'tests', 'fixtures', 'icon-editor', 'fixture-manifest.json');
  const data = readFileSync(basePath, 'utf8');
  return JSON.parse(data);
}

function buildManifestFromSummary(summary) {
  const entries = [];
  for (const asset of [...summary.fixtureOnlyAssets].sort((a, b) => (a.category + a.name).localeCompare(b.category + b.name))) {
    const rel = asset.category === 'script' ? join('scripts', asset.name) : join('tests', asset.name);
    entries.push({
      key: `${asset.category}:${rel}`.toLowerCase(),
      category: asset.category,
      path: rel,
      sizeBytes: asset.sizeBytes ?? 0,
      hash: asset.hash,
    });
  }
  return entries;
}

test('fixture manifest matches baseline and is deterministic', () => {
  const summary = loadReport();
  const baseline = loadBaseline();

  const current = buildManifestFromSummary(summary);

  const baseMap = Object.fromEntries(baseline.entries.map(e => [e.key, e]));
  const curMap = Object.fromEntries(current.map(e => [e.key, e]));

  // sets equal
  assert.deepEqual(new Set(Object.keys(curMap)), new Set(Object.keys(baseMap)));

  // values equal (hash and size)
  for (const k of Object.keys(curMap)) {
    assert.ok(baseMap[k], `baseline missing key: ${k}`);
    assert.equal(curMap[k].hash, baseMap[k].hash, `hash mismatch for ${k}`);
    assert.equal(Number(curMap[k].sizeBytes), Number(baseMap[k].sizeBytes), `size mismatch for ${k}`);
  }
});


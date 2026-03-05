import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { join, dirname, posix } from 'node:path';
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
    const normalizedName = typeof asset.name === 'string' ? asset.name.replace(/\\/g, '/') : '';
    let rel;
    switch (asset.category) {
      case 'script':
        rel = posix.join('scripts', normalizedName);
        break;
      case 'test':
        rel = posix.join('tests', normalizedName);
        break;
      case 'resource':
        rel = posix.join('resource', normalizedName);
        break;
      default:
        rel = posix.join(asset.category ?? 'unknown', normalizedName);
        break;
    }
    entries.push({
      key: `${asset.category}:${rel}`.toLowerCase().replace(/\\/g, '/'),
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

  const norm = (k) => k.toLowerCase().replace(/\\/g, '/');
  const baseMap = Object.fromEntries(baseline.entries.map(e => [norm(e.key), e]));
  const curMap = Object.fromEntries(current.map(e => [norm(e.key), e]));

  // sets equal
  assert.deepEqual(new Set(Object.keys(curMap)), new Set(Object.keys(baseMap)));

  // values equal (hash and size)
  for (const k of Object.keys(curMap)) {
    assert.ok(baseMap[k], `baseline missing key: ${k}`);
    assert.equal(curMap[k].hash, baseMap[k].hash, `hash mismatch for ${k}`);
    assert.equal(Number(curMap[k].sizeBytes), Number(baseMap[k].sizeBytes), `size mismatch for ${k}`);
  }
});

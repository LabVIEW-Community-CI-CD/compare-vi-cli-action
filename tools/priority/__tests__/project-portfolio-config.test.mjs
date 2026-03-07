import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..', '..');
const configPath = path.join(repoRoot, 'tools', 'priority', 'project-portfolio.json');
const config = JSON.parse(readFileSync(configPath, 'utf8'));

test('project portfolio config tracks the expected schema and repos', () => {
  assert.equal(config.schema, 'project-portfolio-config@v1');
  assert.equal(config.owner, 'LabVIEW-Community-CI-CD');
  assert.equal(config.number, 2);
  assert.deepEqual(config.repositories, [
    'LabVIEW-Community-CI-CD/compare-vi-cli-action',
    'LabVIEW-Community-CI-CD/comparevi-history',
  ]);
});

test('project portfolio config item URLs are unique and cover the active programs', () => {
  const urls = config.items.map((item) => item.url);
  assert.equal(new Set(urls).size, urls.length);
  assert.equal(urls.length, 16);
  assert.ok(urls.includes('https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/issues/854'));
  assert.ok(urls.includes('https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/issues/861'));
  assert.ok(urls.includes('https://github.com/LabVIEW-Community-CI-CD/comparevi-history/issues/14'));
  assert.ok(urls.includes('https://github.com/LabVIEW-Community-CI-CD/comparevi-history/issues/15'));
});

test('project portfolio config declares the fields future agents need to reason about the board', () => {
  for (const item of config.items) {
    assert.equal(typeof item.status, 'string');
    assert.equal(typeof item.program, 'string');
    assert.equal(typeof item.phase, 'string');
    assert.equal(typeof item.environmentClass, 'string');
    assert.equal(typeof item.blockingSignal, 'string');
    assert.equal(typeof item.evidenceState, 'string');
  }
});

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
    'LabVIEW-Community-CI-CD/compare-vi-cli-action-fork',
    'LabVIEW-Community-CI-CD/comparevi-history',
    'LabVIEW-Community-CI-CD/labview-icon-editor-demo',
    'svelderrainruiz/labview-icon-editor-demo',
  ]);
});

test('project portfolio config item URLs are unique and cover the tracked portfolio work', () => {
  const parsedUrls = config.items.map((item) => new URL(item.url));
  const urlStrings = parsedUrls.map((item) => item.toString());
  assert.equal(new Set(urlStrings).size, urlStrings.length);
  assert.equal(parsedUrls.length, 59);

  const issueCoordinates = new Set(
    parsedUrls.map((item) => {
      assert.equal(item.protocol, 'https:');
      assert.equal(item.host, 'github.com');
      const [, owner, repo, kind, issueNumber] = item.pathname.split('/');
      assert.equal(kind, 'issues');
      return `${owner}/${repo}#${issueNumber}`;
    }),
  );

  assert.ok(issueCoordinates.has('LabVIEW-Community-CI-CD/compare-vi-cli-action#854'));
  assert.ok(issueCoordinates.has('LabVIEW-Community-CI-CD/compare-vi-cli-action#861'));
  assert.ok(issueCoordinates.has('LabVIEW-Community-CI-CD/compare-vi-cli-action#875'));
  assert.ok(issueCoordinates.has('LabVIEW-Community-CI-CD/compare-vi-cli-action#876'));
  assert.ok(issueCoordinates.has('LabVIEW-Community-CI-CD/compare-vi-cli-action#883'));
  assert.ok(issueCoordinates.has('LabVIEW-Community-CI-CD/compare-vi-cli-action#892'));
  assert.ok(issueCoordinates.has('LabVIEW-Community-CI-CD/compare-vi-cli-action#894'));
  assert.ok(issueCoordinates.has('LabVIEW-Community-CI-CD/compare-vi-cli-action#895'));
  assert.ok(issueCoordinates.has('LabVIEW-Community-CI-CD/compare-vi-cli-action#896'));
  assert.ok(issueCoordinates.has('LabVIEW-Community-CI-CD/compare-vi-cli-action#897'));
  assert.ok(issueCoordinates.has('LabVIEW-Community-CI-CD/compare-vi-cli-action#903'));
  assert.ok(issueCoordinates.has('LabVIEW-Community-CI-CD/compare-vi-cli-action#904'));
  assert.ok(issueCoordinates.has('LabVIEW-Community-CI-CD/compare-vi-cli-action#906'));
  assert.ok(issueCoordinates.has('LabVIEW-Community-CI-CD/compare-vi-cli-action#907'));
  assert.ok(issueCoordinates.has('LabVIEW-Community-CI-CD/compare-vi-cli-action#911'));
  assert.ok(issueCoordinates.has('LabVIEW-Community-CI-CD/compare-vi-cli-action#913'));
  assert.ok(issueCoordinates.has('LabVIEW-Community-CI-CD/compare-vi-cli-action#915'));
  assert.ok(issueCoordinates.has('LabVIEW-Community-CI-CD/compare-vi-cli-action#930'));
  assert.ok(issueCoordinates.has('LabVIEW-Community-CI-CD/compare-vi-cli-action#931'));
  assert.ok(issueCoordinates.has('LabVIEW-Community-CI-CD/compare-vi-cli-action#932'));
  assert.ok(issueCoordinates.has('LabVIEW-Community-CI-CD/compare-vi-cli-action#934'));
  assert.ok(issueCoordinates.has('LabVIEW-Community-CI-CD/compare-vi-cli-action#946'));
  assert.ok(issueCoordinates.has('LabVIEW-Community-CI-CD/compare-vi-cli-action#947'));
  assert.ok(issueCoordinates.has('LabVIEW-Community-CI-CD/compare-vi-cli-action#948'));
  assert.ok(issueCoordinates.has('LabVIEW-Community-CI-CD/compare-vi-cli-action#949'));
  assert.ok(issueCoordinates.has('LabVIEW-Community-CI-CD/compare-vi-cli-action#951'));
  assert.ok(issueCoordinates.has('LabVIEW-Community-CI-CD/compare-vi-cli-action#953'));
  assert.ok(issueCoordinates.has('LabVIEW-Community-CI-CD/compare-vi-cli-action#954'));
  assert.ok(issueCoordinates.has('LabVIEW-Community-CI-CD/compare-vi-cli-action#956'));
  assert.ok(issueCoordinates.has('LabVIEW-Community-CI-CD/compare-vi-cli-action#958'));
  assert.ok(issueCoordinates.has('LabVIEW-Community-CI-CD/compare-vi-cli-action#959'));
  assert.ok(issueCoordinates.has('LabVIEW-Community-CI-CD/compare-vi-cli-action#960'));
  assert.ok(issueCoordinates.has('LabVIEW-Community-CI-CD/compare-vi-cli-action#963'));
  assert.ok(issueCoordinates.has('LabVIEW-Community-CI-CD/compare-vi-cli-action#964'));
  assert.ok(issueCoordinates.has('LabVIEW-Community-CI-CD/compare-vi-cli-action#966'));
  assert.ok(issueCoordinates.has('LabVIEW-Community-CI-CD/compare-vi-cli-action#967'));
  assert.ok(issueCoordinates.has('LabVIEW-Community-CI-CD/compare-vi-cli-action#969'));
  assert.ok(issueCoordinates.has('LabVIEW-Community-CI-CD/compare-vi-cli-action#970'));
  assert.ok(issueCoordinates.has('LabVIEW-Community-CI-CD/compare-vi-cli-action-fork#1'));
  assert.ok(issueCoordinates.has('LabVIEW-Community-CI-CD/comparevi-history#14'));
  assert.ok(issueCoordinates.has('LabVIEW-Community-CI-CD/comparevi-history#15'));
  assert.ok(issueCoordinates.has('LabVIEW-Community-CI-CD/comparevi-history#23'));
  assert.ok(issueCoordinates.has('LabVIEW-Community-CI-CD/comparevi-history#24'));
  assert.ok(issueCoordinates.has('LabVIEW-Community-CI-CD/comparevi-history#25'));
  assert.ok(issueCoordinates.has('LabVIEW-Community-CI-CD/comparevi-history#26'));
  assert.ok(issueCoordinates.has('LabVIEW-Community-CI-CD/labview-icon-editor-demo#4'));
  assert.ok(issueCoordinates.has('svelderrainruiz/labview-icon-editor-demo#5'));
});

test('project portfolio config declares the fields future agents need to reason about the board', () => {
  assert.deepEqual(Object.keys(config.fieldCatalog).sort(), [
    'blockingSignal',
    'environmentClass',
    'evidenceState',
    'phase',
    'portfolioTrack',
    'program',
    'status',
  ]);
  assert.deepEqual(config.fieldCatalog.portfolioTrack.options, [
    'Diagnostics',
    'Approvals',
    'Agent UX',
    'Corpus & Facade',
  ]);

  for (const item of config.items) {
    assert.equal(typeof item.status, 'string');
    assert.equal(typeof item.program, 'string');
    assert.equal(typeof item.phase, 'string');
    assert.equal(typeof item.environmentClass, 'string');
    assert.equal(typeof item.blockingSignal, 'string');
    assert.equal(typeof item.evidenceState, 'string');
    assert.equal(typeof item.portfolioTrack, 'string');
    assert.ok(config.fieldCatalog.status.options.includes(item.status));
    assert.ok(config.fieldCatalog.program.options.includes(item.program));
    assert.ok(config.fieldCatalog.phase.options.includes(item.phase));
    assert.ok(config.fieldCatalog.environmentClass.options.includes(item.environmentClass));
    assert.ok(config.fieldCatalog.blockingSignal.options.includes(item.blockingSignal));
    assert.ok(config.fieldCatalog.evidenceState.options.includes(item.evidenceState));
    assert.ok(config.fieldCatalog.portfolioTrack.options.includes(item.portfolioTrack));
  }
});

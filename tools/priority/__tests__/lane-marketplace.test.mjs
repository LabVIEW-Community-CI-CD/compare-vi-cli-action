import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, readFile, writeFile } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import {
  collectMarketplaceSnapshot,
  loadMarketplaceRegistry,
  parseArgs,
  rankMarketplaceEntries,
  selectMarketplaceRecommendation
} from '../lane-marketplace.mjs';

test('lane-marketplace parseArgs applies defaults and accepts overrides', () => {
  const defaults = parseArgs(['node', 'lane-marketplace.mjs']);
  assert.equal(defaults.registryPath, path.join('tools', 'priority', 'lane-marketplace.json'));
  assert.equal(defaults.outputPath, path.join('tests', 'results', '_agent', 'marketplace', 'lane-marketplace-snapshot.json'));
  assert.equal(defaults.help, false);

  const explicit = parseArgs([
    'node',
    'lane-marketplace.mjs',
    '--registry',
    'tmp/registry.json',
    '--output',
    'tmp/out.json'
  ]);
  assert.equal(explicit.registryPath, 'tmp/registry.json');
  assert.equal(explicit.outputPath, 'tmp/out.json');
});

test('lane-marketplace loadMarketplaceRegistry rejects duplicate ids and slugs', async () => {
  const tempRoot = await mkdtemp(path.join(os.tmpdir(), 'lane-marketplace-registry-'));
  const registryPath = path.join(tempRoot, 'registry.json');
  await writeFile(registryPath, JSON.stringify({
    schema: 'priority/lane-marketplace-registry@v1',
    repositories: [
      {
        id: 'one',
        slug: 'owner/repo',
        authorityTier: 'upstream-integration',
        laneClass: 'upstream',
        promotionRail: 'integration'
      },
      {
        id: 'one',
        slug: 'owner/repo-two',
        authorityTier: 'shared-platform',
        laneClass: 'consumer-platform',
        promotionRail: 'shared-platform'
      }
    ]
  }), 'utf8');

  await assert.rejects(
    () => loadMarketplaceRegistry(registryPath, { repoRoot: tempRoot }),
    /Duplicate marketplace repository id/
  );
});

test('lane-marketplace rankMarketplaceEntries prioritizes eligible higher-authority lanes first', () => {
  const ranked = rankMarketplaceEntries([
    {
      id: 'personal',
      repository: 'owner/personal',
      authorityTier: 'personal-authoring',
      promotionRail: 'authoring',
      laneClass: 'personal-fork',
      standingLabels: ['fork-standing-priority'],
      enabled: true,
      eligible: true,
      reason: 'standing-ready',
      message: '',
      standing: { number: 9 }
    },
    {
      id: 'upstream',
      repository: 'owner/upstream',
      authorityTier: 'upstream-integration',
      promotionRail: 'integration',
      laneClass: 'upstream',
      standingLabels: ['standing-priority'],
      enabled: true,
      eligible: true,
      reason: 'standing-ready',
      message: '',
      standing: { number: 1 }
    },
    {
      id: 'idle',
      repository: 'owner/idle',
      authorityTier: 'shared-platform',
      promotionRail: 'shared-platform',
      laneClass: 'consumer-platform',
      standingLabels: ['standing-priority'],
      enabled: true,
      eligible: false,
      reason: 'queue-empty',
      message: '',
      standing: null
    }
  ]);

  assert.equal(ranked[0].repository, 'owner/upstream');
  assert.equal(ranked[1].repository, 'owner/personal');
  assert.equal(ranked[2].repository, 'owner/idle');
  assert.equal(ranked[0].ranking.order, 1);
});

test('lane-marketplace collectMarketplaceSnapshot builds ranked standing and queue-empty entries', async () => {
  const tempRoot = await mkdtemp(path.join(os.tmpdir(), 'lane-marketplace-snapshot-'));
  const registryPath = path.join(tempRoot, 'registry.json');
  await writeFile(registryPath, JSON.stringify({
    schema: 'priority/lane-marketplace-registry@v1',
    repositories: [
      {
        id: 'upstream',
        slug: 'owner/upstream',
        authorityTier: 'upstream-integration',
        laneClass: 'upstream',
        promotionRail: 'integration',
        standingLabels: ['standing-priority'],
        enabled: true
      },
      {
        id: 'consumer',
        slug: 'owner/consumer',
        authorityTier: 'consumer-proving',
        laneClass: 'consumer-template',
        promotionRail: 'consumer-proving',
        standingLabels: ['standing-priority'],
        enabled: true
      }
    ]
  }), 'utf8');

  const snapshot = await collectMarketplaceSnapshot({
    repoRoot: tempRoot,
    registryPath,
    resolveStandingPriorityForRepoFn: async (_repoRoot, slug) => {
      if (slug === 'owner/upstream') {
        return {
          found: {
            number: 41,
            source: 'gh',
            repoSlug: slug
          }
        };
      }
      return { found: null };
    },
    fetchIssueFn: async (number, _repoRoot, slug) => ({
      number,
      title: `${slug} standing`,
      url: `https://example.test/${slug}/issues/${number}`,
      labels: [{ name: 'standing-priority' }]
    }),
    classifyNoStandingPriorityConditionFn: async (_repoRoot, slug) => ({
      status: 'classified',
      reason: 'queue-empty',
      repository: slug,
      openIssueCount: 0,
      message: `${slug} is idle`
    })
  });

  assert.equal(snapshot.summary.repositoryCount, 2);
  assert.equal(snapshot.summary.eligibleLaneCount, 1);
  assert.equal(snapshot.summary.queueEmptyCount, 1);
  assert.equal(snapshot.summary.topEligibleLane.repository, 'owner/upstream');
  assert.equal(snapshot.entries[0].repository, 'owner/upstream');
  assert.equal(snapshot.entries[0].standing.number, 41);
  assert.equal(snapshot.entries[1].reason, 'queue-empty');
});

test('lane-marketplace selectMarketplaceRecommendation skips the current repository when requested', () => {
  const recommendation = selectMarketplaceRecommendation(
    {
      entries: [
        {
          repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
          eligible: true,
          authorityTier: 'upstream-integration',
          laneClass: 'upstream',
          promotionRail: 'integration',
          reason: 'standing-ready',
          standingLabels: ['standing-priority'],
          standing: { number: 1510, url: 'https://example.test/upstream/1510', title: 'Current repo lane' },
          ranking: { order: 1 }
        },
        {
          repository: 'LabVIEW-Community-CI-CD/comparevi-history',
          eligible: true,
          authorityTier: 'shared-platform',
          laneClass: 'consumer-platform',
          promotionRail: 'shared-platform',
          reason: 'standing-ready',
          standingLabels: ['standing-priority'],
          standing: { number: 186, url: 'https://example.test/history/186', title: 'Shared platform lane' },
          ranking: { order: 2 }
        }
      ]
    },
    {
      currentRepository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      requireDifferentRepository: true
    }
  );

  assert.equal(recommendation.repository, 'LabVIEW-Community-CI-CD/comparevi-history');
  assert.equal(recommendation.issueNumber, 186);
});

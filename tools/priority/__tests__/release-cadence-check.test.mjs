import assert from 'node:assert/strict';
import test from 'node:test';

import {
  buildIssueBody,
  evaluateReleaseCadence,
  parseCompareviToolsPublishLog,
  parseCompareViSharedPublishLog,
} from '../release-cadence-check.mjs';

const toolsLog = [
  'build-and-push  UNKNOWN STEP  2026-03-09T10:05:59Z - Version: `0.6.3-tools.8`',
  'build-and-push  UNKNOWN STEP  2026-03-09T10:05:59Z - Channel: `stable`',
  'build-and-push  UNKNOWN STEP  2026-03-09T10:05:59Z - Stable family version: `0.6.3`',
  'build-and-push  UNKNOWN STEP  2026-03-09T10:05:59Z - Source ref: `develop`',
  'build-and-push  UNKNOWN STEP  2026-03-09T10:05:59Z ## Published tags',
  'build-and-push  UNKNOWN STEP  2026-03-09T10:05:59Z - `ghcr.io/labview-community-ci-cd/comparevi-tools:v0.6.3`',
].join('\n');

const sharedStableLog = [
  'build-pack-publish  UNKNOWN STEP  2026-02-01T12:00:00Z echo "- Version: \\`0.2.0\\`"',
  'build-pack-publish  UNKNOWN STEP  2026-02-01T12:00:00Z echo "- Channel: \\`stable\\`"',
  'build-pack-publish  UNKNOWN STEP  2026-02-01T12:00:00Z echo "- Published: \\`true\\`"',
  'build-pack-publish  UNKNOWN STEP  2026-02-01T12:00:00Z echo "- Registry: \\`https://nuget.pkg.github.com/LabVIEW-Community-CI-CD/index.json\\`"',
].join('\n');

const sharedRcLog = [
  'build-pack-publish  UNKNOWN STEP  2026-03-05T17:40:39Z echo "- Version: \\`0.2.0-rc.1\\`"',
  'build-pack-publish  UNKNOWN STEP  2026-03-05T17:40:39Z echo "- Channel: \\`rc\\`"',
  'build-pack-publish  UNKNOWN STEP  2026-03-05T17:40:39Z echo "- Published: \\`true\\`"',
  'build-pack-publish  UNKNOWN STEP  2026-03-05T17:40:39Z echo "- Registry: \\`https://nuget.pkg.github.com/LabVIEW-Community-CI-CD/index.json\\`"',
].join('\n');

test('parseCompareviToolsPublishLog extracts stable family evidence from the publish summary', () => {
  const parsed = parseCompareviToolsPublishLog(toolsLog);

  assert.equal(parsed.version, '0.6.3-tools.8');
  assert.equal(parsed.channel, 'stable');
  assert.equal(parsed.stableFamilyVersion, '0.6.3');
  assert.equal(parsed.sourceRef, 'develop');
  assert.deepEqual(parsed.publishedTags, ['ghcr.io/labview-community-ci-cd/comparevi-tools:v0.6.3']);
});

test('parseCompareViSharedPublishLog normalizes escaped backticks from workflow command logs', () => {
  const parsed = parseCompareViSharedPublishLog(sharedStableLog);

  assert.equal(parsed.version, '0.2.0');
  assert.equal(parsed.channel, 'stable');
  assert.equal(parsed.published, true);
  assert.equal(parsed.registry, 'https://nuget.pkg.github.com/LabVIEW-Community-CI-CD/index.json');
});

test('evaluateReleaseCadence treats workflow-run evidence as authoritative for stable freshness', () => {
  const report = evaluateReleaseCadence({
    now: new Date('2026-03-09T18:16:55.678Z'),
    staleThresholdDays: 45,
    toolsRuns: [
      {
        databaseId: 22848241063,
        createdAt: '2026-03-09T10:04:30Z',
        displayTitle: 'Publish Tools Image',
        event: 'workflow_dispatch',
        headBranch: 'develop',
        status: 'completed',
        conclusion: 'success',
        url: 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/actions/runs/22848241063',
      },
    ],
    sharedRuns: [
      {
        databaseId: 22728813159,
        createdAt: '2026-03-05T17:40:07Z',
        displayTitle: 'Publish CompareVi.Shared Package',
        event: 'workflow_dispatch',
        headBranch: 'develop',
        status: 'completed',
        conclusion: 'success',
        url: 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/actions/runs/22728813159',
      },
    ],
    fetchToolsRunLog: () => toolsLog,
    fetchSharedRunLog: () => sharedRcLog,
  });

  assert.equal(report.staleDetected, true);

  const toolsStream = report.streams.find((stream) => stream.name === 'comparevi-tools');
  assert.equal(toolsStream.stale, false);
  assert.equal(toolsStream.latestStableRef, 'v0.6.3');
  assert.equal(toolsStream.latestPublishUtc, '2026-03-09T10:04:30Z');

  const sharedStream = report.streams.find((stream) => stream.name === 'CompareVi.Shared');
  assert.equal(sharedStream.stale, true);
  assert.equal(sharedStream.latestStableRef, 'none');
  assert.equal(sharedStream.latestObserved.version, '0.2.0-rc.1');
  assert.equal(sharedStream.latestObserved.channel, 'rc');
});

test('buildIssueBody reports latest observed non-stable evidence instead of claiming the stream is missing', () => {
  const report = evaluateReleaseCadence({
    now: new Date('2026-03-09T18:16:55.678Z'),
    staleThresholdDays: 45,
    toolsRuns: [
      {
        databaseId: 22848241063,
        createdAt: '2026-03-09T10:04:30Z',
        displayTitle: 'Publish Tools Image',
        event: 'workflow_dispatch',
        headBranch: 'develop',
        status: 'completed',
        conclusion: 'success',
        url: 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/actions/runs/22848241063',
      },
    ],
    sharedRuns: [
      {
        databaseId: 22728813159,
        createdAt: '2026-03-05T17:40:07Z',
        displayTitle: 'Publish CompareVi.Shared Package',
        event: 'workflow_dispatch',
        headBranch: 'develop',
        status: 'completed',
        conclusion: 'success',
        url: 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/actions/runs/22728813159',
      },
    ],
    fetchToolsRunLog: () => toolsLog,
    fetchSharedRunLog: () => sharedRcLog,
  });

  const body = buildIssueBody(report);

  assert.match(body, /comparevi-tools \| `v0\.6\.3` \| 2026-03-09T10:04:30Z \| 0 \| fresh/);
  assert.match(body, /CompareVi\.Shared \| `none` \| missing \| n\/a \| stale \| no stable publish; latest observed `0\.2\.0-rc\.1` \(rc, published=true\)/);
  assert.match(body, /Evidence source: successful publish workflow logs, not package-registry enumeration\./);
});

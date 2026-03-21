import test from 'node:test';
import assert from 'node:assert/strict';
import { buildForkLaneIdentity, normalizeMirrorOfPointer } from '../lib/fork-lane-identity.mjs';

test('normalizeMirrorOfPointer normalizes repository and issue metadata', () => {
  assert.deepEqual(
    normalizeMirrorOfPointer({
      number: '319',
      repository: ' owner/repo ',
      url: ' https://github.com/owner/repo/issues/319 '
    }),
    {
      repository: 'owner/repo',
      issueNumber: 319,
      issueUrl: 'https://github.com/owner/repo/issues/319'
    }
  );
});

test('buildForkLaneIdentity returns upstream-standing when no fork context exists', () => {
  const identity = buildForkLaneIdentity({
    branch: 'issue/1487-fork-standing-priority-identity-surface',
    issueSource: 'router',
    issueNumber: 1487,
    issueUrl: 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/issues/1487',
    upstreamRepository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action'
  });

  assert.equal(identity.kind, 'upstream-standing');
  assert.equal(identity.forkContext, null);
  assert.equal(identity.forkIssue, null);
  assert.equal(identity.canonicalIssue.issueNumber, 1487);
});

test('buildForkLaneIdentity returns fork-plane-branch for fork-targeted lanes without fork issue mirrors', () => {
  const identity = buildForkLaneIdentity({
    branch: 'issue/origin-1490-validate-same-owner-fork-standing-lanes',
    issueSource: 'router',
    issueNumber: 1490,
    issueUrl: 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/issues/1490',
    forkRemote: 'origin',
    forkRepository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action-fork',
    upstreamRepository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
    dispatchRepository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action-fork'
  });

  assert.equal(identity.kind, 'fork-plane-branch');
  assert.equal(identity.forkContext.remote, 'origin');
  assert.equal(identity.forkContext.repository, 'LabVIEW-Community-CI-CD/compare-vi-cli-action-fork');
  assert.equal(identity.forkIssue, null);
  assert.equal(identity.canonicalIssue.issueNumber, 1490);
});

test('buildForkLaneIdentity returns fork-standing-mirror when a fork issue differs from the canonical issue', () => {
  const identity = buildForkLaneIdentity({
    branch: 'issue/personal-969-fork-lane-dogfood',
    issueSource: 'router',
    issueNumber: 969,
    issueUrl: 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/issues/969',
    localIssueNumber: 319,
    localIssueUrl: 'https://github.com/svelderrainruiz/compare-vi-cli-action/issues/319',
    mirrorOf: {
      number: 969,
      repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      url: 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/issues/969'
    },
    forkRemote: 'personal',
    forkRepository: 'svelderrainruiz/compare-vi-cli-action',
    upstreamRepository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
    dispatchRepository: 'svelderrainruiz/compare-vi-cli-action'
  });

  assert.equal(identity.kind, 'fork-standing-mirror');
  assert.equal(identity.forkContext.remote, 'personal');
  assert.equal(identity.forkIssue.issueNumber, 319);
  assert.equal(identity.forkIssue.issueUrl, 'https://github.com/svelderrainruiz/compare-vi-cli-action/issues/319');
  assert.equal(identity.canonicalIssue.issueNumber, 969);
  assert.equal(identity.canonicalIssue.repository, 'LabVIEW-Community-CI-CD/compare-vi-cli-action');
});

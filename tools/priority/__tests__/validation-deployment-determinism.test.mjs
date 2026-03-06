import test from 'node:test';
import assert from 'node:assert/strict';
import {
  buildDeploymentEntries,
  evaluateDeploymentDeterminism,
  parseRunIdFromUrl
} from '../assert-validation-deployment-determinism.mjs';

function makeDeployment({ id, sha = 'abc', createdAt = '2026-03-06T00:00:00Z', ref = 'refs/heads/develop' }) {
  return {
    id,
    sha,
    ref,
    created_at: createdAt,
    updated_at: createdAt
  };
}

function makeStatus({ id, state, createdAt, runId }) {
  return {
    id,
    state,
    created_at: createdAt,
    updated_at: createdAt,
    log_url: `https://github.com/example/repo/actions/runs/${runId}/job/1`
  };
}

test('parseRunIdFromUrl extracts run id from actions URL', () => {
  assert.equal(
    parseRunIdFromUrl('https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/actions/runs/22742469667/job/1'),
    '22742469667'
  );
  assert.equal(parseRunIdFromUrl('https://example.test/no-run-here'), null);
});

test('buildDeploymentEntries normalizes latest state and run ownership metadata', () => {
  const deployments = [makeDeployment({ id: 42 })];
  const statusesByDeployment = {
    42: [
      makeStatus({ id: 2, state: 'success', createdAt: '2026-03-06T00:10:00Z', runId: '1002' }),
      makeStatus({ id: 1, state: 'in_progress', createdAt: '2026-03-06T00:09:00Z', runId: '1002' })
    ]
  };

  const entries = buildDeploymentEntries(deployments, statusesByDeployment);
  assert.equal(entries.length, 1);
  assert.equal(entries[0].latestState, 'success');
  assert.equal(entries[0].latestRunId, '1002');
  assert.deepEqual(entries[0].runIds, ['1002']);
});

test('evaluateDeploymentDeterminism passes when current run owns latest active deployment', () => {
  const deployments = [
    makeDeployment({ id: 101, sha: 'abc', createdAt: '2026-03-06T00:11:00Z' }),
    makeDeployment({ id: 100, sha: 'abc', createdAt: '2026-03-06T00:10:00Z' })
  ];
  const statusesByDeployment = {
    101: [makeStatus({ id: 3, state: 'success', createdAt: '2026-03-06T00:11:30Z', runId: '2001' })],
    100: [makeStatus({ id: 2, state: 'inactive', createdAt: '2026-03-06T00:11:20Z', runId: '1999' })]
  };
  const entries = buildDeploymentEntries(deployments, statusesByDeployment);
  const evaluation = evaluateDeploymentDeterminism(entries, { runId: '2001', sha: 'abc' });

  assert.equal(evaluation.ok, true);
  assert.deepEqual(evaluation.issues, []);
  assert.equal(evaluation.latestActive.id, 101);
});

test('evaluateDeploymentDeterminism fails when latest active deployment belongs to another run', () => {
  const deployments = [
    makeDeployment({ id: 201, sha: 'def', createdAt: '2026-03-06T00:12:00Z' }),
    makeDeployment({ id: 200, sha: 'def', createdAt: '2026-03-06T00:11:00Z' })
  ];
  const statusesByDeployment = {
    201: [makeStatus({ id: 5, state: 'success', createdAt: '2026-03-06T00:12:20Z', runId: '3002' })],
    200: [
      makeStatus({ id: 4, state: 'success', createdAt: '2026-03-06T00:11:20Z', runId: '3001' }),
      makeStatus({ id: 3, state: 'in_progress', createdAt: '2026-03-06T00:11:10Z', runId: '3001' })
    ]
  };
  const entries = buildDeploymentEntries(deployments, statusesByDeployment);
  const evaluation = evaluateDeploymentDeterminism(entries, { runId: '3001', sha: 'def' });

  assert.equal(evaluation.ok, false);
  assert.ok(evaluation.issues.some((issue) => issue.startsWith('latest-active-owned-by-other-run:3002')));
});

test('evaluateDeploymentDeterminism passes when current run latest deployment is terminal inactive after success', () => {
  const deployments = [makeDeployment({ id: 301, sha: 'ghi', createdAt: '2026-03-06T00:13:00Z' })];
  const statusesByDeployment = {
    301: [
      makeStatus({ id: 7, state: 'inactive', createdAt: '2026-03-06T00:13:20Z', runId: '4001' }),
      makeStatus({ id: 6, state: 'success', createdAt: '2026-03-06T00:13:10Z', runId: '4001' })
    ]
  };
  const entries = buildDeploymentEntries(deployments, statusesByDeployment);
  const evaluation = evaluateDeploymentDeterminism(entries, { runId: '4001', sha: 'ghi' });

  assert.equal(evaluation.ok, true);
  assert.deepEqual(evaluation.issues, []);
  assert.equal(evaluation.latestRunEntry.id, 301);
});

test('evaluateDeploymentDeterminism fails when current run only has inactive state without prior active status', () => {
  const deployments = [makeDeployment({ id: 311, sha: 'ghi2', createdAt: '2026-03-06T00:14:00Z' })];
  const statusesByDeployment = {
    311: [makeStatus({ id: 8, state: 'inactive', createdAt: '2026-03-06T00:14:20Z', runId: '4002' })]
  };
  const entries = buildDeploymentEntries(deployments, statusesByDeployment);
  const evaluation = evaluateDeploymentDeterminism(entries, { runId: '4002', sha: 'ghi2' });

  assert.equal(evaluation.ok, false);
  assert.ok(evaluation.issues.some((issue) => issue.startsWith('current-run-latest-state-not-active:inactive')));
});

test('evaluateDeploymentDeterminism fails when newest deployment belongs to another run even if all deployments are inactive', () => {
  const deployments = [
    makeDeployment({ id: 401, sha: 'jkl', createdAt: '2026-03-06T00:16:00Z' }),
    makeDeployment({ id: 400, sha: 'jkl', createdAt: '2026-03-06T00:15:00Z' })
  ];
  const statusesByDeployment = {
    401: [
      makeStatus({ id: 12, state: 'inactive', createdAt: '2026-03-06T00:16:20Z', runId: '5002' }),
      makeStatus({ id: 11, state: 'success', createdAt: '2026-03-06T00:16:10Z', runId: '5002' })
    ],
    400: [
      makeStatus({ id: 10, state: 'inactive', createdAt: '2026-03-06T00:15:20Z', runId: '5001' }),
      makeStatus({ id: 9, state: 'success', createdAt: '2026-03-06T00:15:10Z', runId: '5001' })
    ]
  };
  const entries = buildDeploymentEntries(deployments, statusesByDeployment);
  const evaluation = evaluateDeploymentDeterminism(entries, { runId: '5001', sha: 'jkl' });

  assert.equal(evaluation.ok, false);
  assert.ok(evaluation.issues.some((issue) => issue.startsWith('latest-deployment-owned-by-other-run:5002')));
});

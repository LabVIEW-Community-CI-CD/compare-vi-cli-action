import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, rm, mkdir, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import {
  loadReleaseRequiredChecks,
  evaluateRequiredReleaseChecks,
  assertRequiredReleaseChecksClean,
  evaluateReleasePrMergeReadiness,
  assertReleasePrMergeReady
} from '../lib/release-pr-checks.mjs';

test('loadReleaseRequiredChecks reads release/* contexts from policy file', async (t) => {
  const repoDir = await mkdtemp(path.join(tmpdir(), 'release-pr-checks-'));
  t.after(() => rm(repoDir, { recursive: true, force: true }));
  await mkdir(path.join(repoDir, 'tools', 'policy'), { recursive: true });
  await writeFile(
    path.join(repoDir, 'tools', 'policy', 'branch-required-checks.json'),
    `${JSON.stringify({
      branches: {
        'release/*': ['lint', 'pester']
      }
    })}\n`,
    'utf8'
  );

  const checks = loadReleaseRequiredChecks(repoDir);
  assert.deepEqual(checks, ['lint', 'pester']);
});

test('evaluateRequiredReleaseChecks accepts prefixed workflow check names', () => {
  const evaluation = evaluateRequiredReleaseChecks(
    ['lint', 'session-index'],
    [
      { name: 'Validate / lint', status: 'COMPLETED', conclusion: 'SUCCESS' },
      { name: 'Validate / session-index', status: 'COMPLETED', conclusion: 'SUCCESS' }
    ]
  );
  assert.deepEqual(evaluation, { missing: [], unresolved: [] });
});

test('evaluateRequiredReleaseChecks reports missing and unresolved contexts', () => {
  const evaluation = evaluateRequiredReleaseChecks(
    ['lint', 'pester', 'session-index'],
    [
      { name: 'Validate / lint', status: 'COMPLETED', conclusion: 'SUCCESS' },
      { name: 'Validate / pester', status: 'IN_PROGRESS', conclusion: null }
    ]
  );
  assert.deepEqual(evaluation.missing, ['session-index']);
  assert.equal(evaluation.unresolved.length, 1);
  assert.equal(evaluation.unresolved[0].context, 'pester');
});

test('assertRequiredReleaseChecksClean throws when required checks are not satisfied', () => {
  assert.throws(
    () =>
      assertRequiredReleaseChecksClean(
        ['lint', 'pester'],
        [{ name: 'Validate / lint', status: 'COMPLETED', conclusion: 'SUCCESS' }]
      ),
    /not satisfied/i
  );
});

test('evaluateReleasePrMergeReadiness allows BLOCKED release PRs when mergeable and not overridden by topology', () => {
  const evaluation = evaluateReleasePrMergeReadiness({
    mergeStateStatus: 'BLOCKED',
    mergeable: 'MERGEABLE'
  });
  assert.equal(evaluation.allowed, true);
  assert.equal(evaluation.reason, null);
});

test('evaluateReleasePrMergeReadiness rejects conflicting or behind release PR states', () => {
  assert.equal(
    evaluateReleasePrMergeReadiness({ mergeStateStatus: 'BLOCKED', mergeable: 'CONFLICTING' }).allowed,
    false
  );
  assert.equal(
    evaluateReleasePrMergeReadiness({ mergeStateStatus: 'BEHIND', mergeable: 'MERGEABLE' }).allowed,
    false
  );
});

test('assertReleasePrMergeReady honors allow-dirty override', () => {
  assert.doesNotThrow(() =>
    assertReleasePrMergeReady(
      {
        mergeStateStatus: 'DIRTY',
        mergeable: 'CONFLICTING'
      },
      { allowDirty: true }
    )
  );
});

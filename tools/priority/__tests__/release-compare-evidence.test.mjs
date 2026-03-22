import test from 'node:test';
import assert from 'node:assert/strict';
import { collectBlockingCompareEvidence } from '../lib/release-compare-evidence.mjs';

test('collectBlockingCompareEvidence requires both compare workflows to be green with artifacts', async () => {
  const calls = [];
  const ghJsonFn = async (args) => {
    calls.push(args.join(' '));
    const cmd = args.join(' ');
    if (cmd.includes('run list') && cmd.includes('validate.yml')) {
      return [
        {
          databaseId: 101,
          status: 'completed',
          conclusion: 'success',
          url: 'https://example.com/runs/101',
          headBranch: 'release/v1.2.3',
          createdAt: '2026-03-05T00:00:00Z'
        }
      ];
    }
    if (cmd.includes('run list') && cmd.includes('fixture-drift.yml')) {
      return [
        {
          databaseId: 102,
          status: 'completed',
          conclusion: 'success',
          url: 'https://example.com/runs/102',
          headBranch: 'release/v1.2.3',
          createdAt: '2026-03-05T00:01:00Z'
        }
      ];
    }
    if (cmd.includes('run view 101')) {
      return { url: 'https://example.com/runs/101', artifacts: [{ name: 'validate-issue-snapshot', sizeInBytes: 1234 }] };
    }
    if (cmd.includes('run view 102')) {
      return { url: 'https://example.com/runs/102', artifacts: [{ name: 'fixture-drift-results', sizeInBytes: 5678 }] };
    }
    throw new Error(`Unexpected gh args: ${cmd}`);
  };

  const evidence = await collectBlockingCompareEvidence({
    repoSlug: 'owner/repo',
    branch: 'release/v1.2.3',
    ghJsonFn
  });

  assert.equal(evidence.length, 2);
  assert.equal(evidence[0].workflow, 'validate.yml');
  assert.equal(evidence[1].workflow, 'fixture-drift.yml');
  assert.equal(calls.length, 4);
});

test('collectBlockingCompareEvidence fails when a workflow run is missing', async () => {
  const ghJsonFn = async (args) => {
    if (args.includes('validate.yml')) {
      return [];
    }
    return [];
  };

  await assert.rejects(
    () =>
      collectBlockingCompareEvidence({
        repoSlug: 'owner/repo',
        branch: 'release/v1.2.3',
        ghJsonFn
      }),
    /Missing required compare evidence run/i
  );
});

test('collectBlockingCompareEvidence fails when a workflow is not successful', async () => {
  const ghJsonFn = async (args) => {
    if (args.includes('validate.yml')) {
      return [
        {
          databaseId: 101,
          status: 'completed',
          conclusion: 'failure'
        }
      ];
    }
    return [];
  };

  await assert.rejects(
    () =>
      collectBlockingCompareEvidence({
        repoSlug: 'owner/repo',
        branch: 'release/v1.2.3',
        ghJsonFn
      }),
    /not green/i
  );
});

test('collectBlockingCompareEvidence fails when artifacts are missing', async () => {
  const ghJsonFn = async (args) => {
    if (args.includes('validate.yml')) {
      return [
        {
          databaseId: 101,
          status: 'completed',
          conclusion: 'success'
        }
      ];
    }
    if (args.includes('run view')) {
      return { artifacts: [] };
    }
    return [];
  };

  await assert.rejects(
    () =>
      collectBlockingCompareEvidence({
        repoSlug: 'owner/repo',
        branch: 'release/v1.2.3',
        ghJsonFn
      }),
    /has no artifacts/i
  );
});

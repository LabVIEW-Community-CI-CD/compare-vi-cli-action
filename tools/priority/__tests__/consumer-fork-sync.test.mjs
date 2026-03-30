import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';

import { DEFAULT_OUTPUT_PATH, parseArgs, runConsumerForkSync } from '../consumer-fork-sync.mjs';

function writeJson(filePath, payload) {
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
  fs.writeFileSync(filePath, `${JSON.stringify(payload, null, 2)}\n`, 'utf8');
}

function createPolicy({ syncPolicy = 'fast-forward-only' } = {}) {
  return {
    schema: 'priority/downstream-repo-graph-policy@v1',
    compareRepository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
    repositories: [
      {
        id: 'canonical-template',
        repository: 'LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate',
        kind: 'canonical-template',
        roles: [
          {
            id: 'template-canonical-development',
            role: 'canonical-development',
            branch: 'develop',
            required: true
          }
        ]
      },
      {
        id: 'org-consumer-fork',
        repository: 'LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate-fork',
        kind: 'consumer-fork',
        roles: [
          {
            id: 'org-fork-canonical-development',
            role: 'canonical-development-mirror',
            branch: 'develop',
            required: true,
            syncPolicy,
            tracksRoleId: 'template-canonical-development'
          }
        ]
      }
    ]
  };
}

test('parseArgs accepts apply mode and report paths', () => {
  const options = parseArgs([
    'node',
    'consumer-fork-sync.mjs',
    '--repo-root',
    'repo',
    '--policy',
    'policy.json',
    '--output',
    'sync.json',
    '--repo',
    'example/repo',
    '--apply'
  ]);

  assert.equal(options.repoRoot, 'repo');
  assert.equal(options.policyPath, 'policy.json');
  assert.equal(options.outputPath, 'sync.json');
  assert.equal(options.repo, 'example/repo');
  assert.equal(options.apply, true);
});

test('runConsumerForkSync reports sync-ready on dry run when mirror is strictly behind canonical head', async () => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'consumer-fork-sync-dry-'));
  const policyPath = path.join(tmpDir, 'policy.json');
  const outputPath = path.join(tmpDir, 'sync.json');
  writeJson(policyPath, createPolicy());

  const { report } = await runConsumerForkSync(
    {
      repoRoot: tmpDir,
      policyPath,
      outputPath
    },
    {
      runGhJsonFn: (args) => {
        switch (args[1]) {
          case 'repos/LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate-fork/branches/develop':
            return { commit: { sha: 'fork123' } };
          case 'repos/LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate/branches/develop':
            return { commit: { sha: 'tpl999' } };
          case 'repos/LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate/compare/fork123...tpl999':
            return { status: 'ahead', ahead_by: 4, behind_by: 0, total_commits: 4 };
          default:
            throw new Error(`Unexpected call: ${args.join(' ')}`);
        }
      }
    }
  );

  assert.equal(report.summary.status, 'pending');
  assert.equal(report.summary.targetCount, 1);
  assert.equal(report.summary.syncReadyCount, 1);
  assert.equal(report.targets[0].status, 'sync-ready');
  assert.equal(report.targets[0].reason, 'fast-forward-ready');
  assert.equal(report.targets[0].compare.status, 'ahead');
});

test('runConsumerForkSync applies a fast-forward patch when --apply is set', async () => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'consumer-fork-sync-apply-'));
  writeJson(path.join(tmpDir, 'tools', 'policy', 'downstream-repo-graph.json'), createPolicy());
  const calls = [];

  const { report, outputPath } = await runConsumerForkSync(
    {
      repoRoot: tmpDir,
      apply: true
    },
    {
      runGhJsonFn: (args) => {
        calls.push(args);
        switch (args[1]) {
          case 'repos/LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate-fork/branches/develop':
            return { commit: { sha: 'fork123' } };
          case 'repos/LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate/branches/develop':
            return { commit: { sha: 'tpl999' } };
          case 'repos/LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate/compare/fork123...tpl999':
            return { status: 'ahead', ahead_by: 4, behind_by: 0, total_commits: 4 };
          case '-X':
            return {
              ref: 'refs/heads/develop',
              object: { sha: 'tpl999' }
            };
          default:
            throw new Error(`Unexpected call: ${args.join(' ')}`);
        }
      }
    }
  );

  assert.equal(report.summary.status, 'pass');
  assert.equal(report.summary.syncedCount, 1);
  assert.equal(report.targets[0].status, 'synced');
  assert.equal(report.targets[0].patch.resultingSha, 'tpl999');
  assert.match(outputPath, new RegExp(DEFAULT_OUTPUT_PATH.replace(/[.*+?^${}()|[\]\\]/g, '\\$&').replace(/\//g, '[\\\\/]')));
  const patchCall = calls.find((args) => args[1] === '-X');
  assert.deepEqual(patchCall, [
    'api',
    '-X',
    'PATCH',
    'repos/LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate-fork/git/refs/heads/develop',
    '-f',
    'sha=tpl999',
    '-F',
    'force=false'
  ]);
});

test('runConsumerForkSync blocks diverged mirror history', async () => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'consumer-fork-sync-diverged-'));
  writeJson(path.join(tmpDir, 'tools', 'policy', 'downstream-repo-graph.json'), createPolicy());

  const { report } = await runConsumerForkSync(
    {
      repoRoot: tmpDir
    },
    {
      runGhJsonFn: (args) => {
        switch (args[1]) {
          case 'repos/LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate-fork/branches/develop':
            return { commit: { sha: 'fork123' } };
          case 'repos/LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate/branches/develop':
            return { commit: { sha: 'tpl999' } };
          case 'repos/LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate/compare/fork123...tpl999':
            return { status: 'diverged', ahead_by: 2, behind_by: 1, total_commits: 3 };
          default:
            throw new Error(`Unexpected call: ${args.join(' ')}`);
        }
      }
    }
  );

  assert.equal(report.summary.status, 'fail');
  assert.equal(report.summary.blockedCount, 1);
  assert.equal(report.targets[0].status, 'blocked');
  assert.equal(report.targets[0].reason, 'diverged-history');
});

test('runConsumerForkSync ignores consumer-fork roles without an explicit sync policy', async () => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'consumer-fork-sync-opt-in-'));
  writeJson(path.join(tmpDir, 'tools', 'policy', 'downstream-repo-graph.json'), createPolicy({ syncPolicy: null }));

  const { report } = await runConsumerForkSync(
    {
      repoRoot: tmpDir
    },
    {
      runGhJsonFn: () => {
        throw new Error('No GitHub calls expected when sync policy is absent.');
      }
    }
  );

  assert.equal(report.summary.status, 'pass');
  assert.equal(report.summary.targetCount, 0);
});

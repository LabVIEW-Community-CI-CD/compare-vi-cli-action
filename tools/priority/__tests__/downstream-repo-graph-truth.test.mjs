import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';

import {
  DEFAULT_OUTPUT_PATH,
  parseArgs,
  runDownstreamRepoGraphTruth
} from '../downstream-repo-graph-truth.mjs';

function writeJson(filePath, payload) {
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
  fs.writeFileSync(filePath, `${JSON.stringify(payload, null, 2)}\n`, 'utf8');
}

function createPolicy() {
  return {
    schema: 'priority/downstream-repo-graph-policy@v1',
    compareRepository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
    repositories: [
      {
        id: 'compare',
        repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
        kind: 'supervisor',
        roles: [
          {
            id: 'compare-producer-lineage',
            role: 'producer-lineage',
            branch: 'develop',
            localRefAlias: 'upstream/develop',
            required: true
          },
          {
            id: 'compare-consumer-proving-source',
            role: 'consumer-proving-source',
            branch: 'develop',
            localRefAlias: 'upstream/develop',
            required: true
          }
        ]
      },
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
          },
          {
            id: 'template-consumer-proving-rail',
            role: 'consumer-proving-rail',
            branch: 'downstream/develop',
            required: false,
            tracksRoleId: 'compare-consumer-proving-source'
          },
          {
            id: 'template-upstream-producer-lineage',
            role: 'upstream-producer-lineage',
            branch: 'upstream/develop',
            required: false,
            tracksRoleId: 'compare-producer-lineage'
          }
        ]
      },
      {
        id: 'comparevi-history',
        repository: 'LabVIEW-Community-CI-CD/comparevi-history',
        kind: 'certified-consumer',
        roles: [
          {
            id: 'comparevi-history-stable-baseline',
            role: 'certified-stable-baseline',
            branch: 'main',
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
            tracksRoleId: 'template-canonical-development'
          }
        ]
      }
    ]
  };
}

test('parseArgs accepts repo graph truth paths', () => {
  const options = parseArgs([
    'node',
    'downstream-repo-graph-truth.mjs',
    '--repo-root',
    'repo',
    '--policy',
    'policy.json',
    '--output',
    'truth.json',
    '--repo',
    'example/repo'
  ]);

  assert.equal(options.repoRoot, 'repo');
  assert.equal(options.policyPath, 'policy.json');
  assert.equal(options.outputPath, 'truth.json');
  assert.equal(options.repo, 'example/repo');
});

test('runDownstreamRepoGraphTruth reports pass when required branches exist and tracked heads align', async () => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'downstream-repo-graph-truth-pass-'));
  const policyPath = path.join(tmpDir, 'policy.json');
  const outputPath = path.join(tmpDir, 'truth.json');
  writeJson(policyPath, createPolicy());

  const branchMap = new Map([
    ['repos/LabVIEW-Community-CI-CD/compare-vi-cli-action/branches/develop', { commit: { sha: 'cmp123' } }],
    ['repos/LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate/branches/develop', { commit: { sha: 'tpl123' } }],
    ['repos/LabVIEW-Community-CI-CD/comparevi-history/branches/main', { commit: { sha: 'hist123' } }],
    ['repos/LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate-fork/branches/develop', { commit: { sha: 'tpl123' } }]
  ]);

  const { report } = await runDownstreamRepoGraphTruth(
    {
      repoRoot: tmpDir,
      policyPath,
      outputPath,
      repo: 'LabVIEW-Community-CI-CD/compare-vi-cli-action'
    },
    {
      resolveRepoSlugFn: (repo) => repo,
      runGhJsonFn: (args) => {
        const response = branchMap.get(args[1]);
        if (response) {
          return response;
        }
        throw new Error('404 Not Found');
      }
    }
  );

  assert.equal(report.summary.status, 'pass');
  assert.equal(report.summary.requiredMissingRoleCount, 0);
  assert.equal(report.summary.optionalMissingRoleCount, 2);
  assert.equal(report.summary.alignmentFailureCount, 0);
  assert.equal(report.summary.repositoryCount, 4);
  assert.equal(report.summary.roleCount, 7);

  const fork = report.repositories.find((entry) => entry.id === 'org-consumer-fork');
  assert.equal(fork.status, 'pass');
  assert.equal(fork.roles[0].relationship.status, 'pass');
  assert.equal(fork.roles[0].relationship.reason, 'head-sha-match');

  const history = report.repositories.find((entry) => entry.id === 'comparevi-history');
  assert.equal(history.status, 'pass');
  assert.equal(history.roles[0].status, 'pass');
  assert.equal(history.roles[0].headSha, 'hist123');
});

test('runDownstreamRepoGraphTruth fails when a required tracked branch drifts from canonical head', async () => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'downstream-repo-graph-truth-fail-'));
  const policyPath = path.join(tmpDir, 'policy.json');
  const outputPath = path.join(tmpDir, 'truth.json');
  writeJson(policyPath, createPolicy());

  const { report } = await runDownstreamRepoGraphTruth(
    {
      repoRoot: tmpDir,
      policyPath,
      outputPath,
      repo: 'LabVIEW-Community-CI-CD/compare-vi-cli-action'
    },
    {
      resolveRepoSlugFn: (repo) => repo,
      runGhJsonFn: (args) => {
        switch (args[1]) {
          case 'repos/LabVIEW-Community-CI-CD/compare-vi-cli-action/branches/develop':
            return { commit: { sha: 'cmp123' } };
          case 'repos/LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate/branches/develop':
            return { commit: { sha: 'tpl123' } };
          case 'repos/LabVIEW-Community-CI-CD/comparevi-history/branches/main':
            return { commit: { sha: 'hist123' } };
          case 'repos/LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate-fork/branches/develop':
            return { commit: { sha: 'drift999' } };
          default:
            throw new Error('404 Not Found');
        }
      }
    }
  );

  assert.equal(report.summary.status, 'fail');
  assert.equal(report.summary.alignmentFailureCount, 1);
  const fork = report.repositories.find((entry) => entry.id === 'org-consumer-fork');
  assert.equal(fork.status, 'fail');
  assert.equal(fork.roles[0].relationship.status, 'fail');
  assert.equal(fork.roles[0].relationship.reason, 'head-sha-mismatch');
});

test('runDownstreamRepoGraphTruth writes the default output path when none is provided', async () => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'downstream-repo-graph-truth-default-output-'));
  writeJson(path.join(tmpDir, 'tools', 'policy', 'downstream-repo-graph.json'), createPolicy());

  const { outputPath } = await runDownstreamRepoGraphTruth(
    {
      repoRoot: tmpDir,
      repo: 'LabVIEW-Community-CI-CD/compare-vi-cli-action'
    },
    {
      resolveRepoSlugFn: (repo) => repo,
      runGhJsonFn: (args) => {
        switch (args[1]) {
          case 'repos/LabVIEW-Community-CI-CD/compare-vi-cli-action/branches/develop':
            return { commit: { sha: 'cmp123' } };
          case 'repos/LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate/branches/develop':
            return { commit: { sha: 'tpl123' } };
          case 'repos/LabVIEW-Community-CI-CD/comparevi-history/branches/main':
            return { commit: { sha: 'hist123' } };
          case 'repos/LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate-fork/branches/develop':
            return { commit: { sha: 'tpl123' } };
          default:
            throw new Error('404 Not Found');
        }
      }
    }
  );

  const escaped = DEFAULT_OUTPUT_PATH.replace(/[.*+?^${}()|[\]\\]/g, '\\$&').replace(/\//g, '[\\\\/]');
  assert.match(outputPath, new RegExp(escaped));
  assert.equal(fs.existsSync(outputPath), true);
});

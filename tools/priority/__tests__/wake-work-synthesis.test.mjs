import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';

import {
  DEFAULT_OUTPUT_PATH,
  parseArgs,
  runWakeWorkSynthesis,
  synthesizeWakeWork
} from '../wake-work-synthesis.mjs';

function writeJson(filePath, payload) {
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
  fs.writeFileSync(filePath, `${JSON.stringify(payload, null, 2)}\n`, 'utf8');
}

function createPolicy() {
  return {
    schema: 'priority/wake-work-synthesis-policy@v1',
    compareRepository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
    classificationDefaults: {
      'stale-artifact': { decision: 'suppress', workKind: 'suppression' },
      'environment-only': { decision: 'monitor', workKind: 'monitoring' },
      'branch-target-drift': { decision: 'compare-governance-work', workKind: 'drift-correction' },
      'platform-permission-gap': { decision: 'compare-governance-work', workKind: 'governance' },
      'live-defect': { decision: 'template-work', workKind: 'defect' }
    },
    liveDefectRouting: {
      compareRepositoryDecision: 'compare-governance-work',
      consumerProvingDecision: 'consumer-proving-drift',
      fallbackDecision: 'investment-work'
    }
  };
}

function createRepoGraphTruth() {
  return {
    schema: 'priority/downstream-repo-graph-truth@v1',
    generatedAt: '2026-03-22T00:00:00.000Z',
    repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
    policy: {
      path: 'tools/policy/downstream-repo-graph.json',
      compareRepository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action'
    },
    repositories: [
      {
        id: 'compare',
        repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
        kind: 'supervisor',
        status: 'pass',
        roles: [
          {
            id: 'compare-producer-lineage',
            role: 'producer-lineage',
            branch: 'develop',
            localRefAlias: 'upstream/develop',
            required: true,
            status: 'pass',
            branchExists: true,
            headSha: 'cmp123',
            relationship: null
          }
        ],
        summary: {
          requiredMissingRoleCount: 0,
          optionalMissingRoleCount: 0,
          alignmentFailureCount: 0,
          unknownRoleCount: 0
        }
      },
      {
        id: 'canonical-template',
        repository: 'LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate',
        kind: 'canonical-template',
        status: 'pass',
        roles: [
          {
            id: 'template-canonical-development',
            role: 'canonical-development',
            branch: 'develop',
            localRefAlias: null,
            required: true,
            status: 'pass',
            branchExists: true,
            headSha: 'tpl123',
            relationship: null
          },
          {
            id: 'template-consumer-proving-rail',
            role: 'consumer-proving-rail',
            branch: 'downstream/develop',
            localRefAlias: null,
            required: false,
            status: 'pass',
            branchExists: true,
            headSha: 'cmp123',
            relationship: {
              tracksRoleId: 'compare-consumer-proving-source',
              status: 'pass',
              trackedHeadSha: 'cmp123',
              reason: 'head-sha-match'
            }
          }
        ],
        summary: {
          requiredMissingRoleCount: 0,
          optionalMissingRoleCount: 0,
          alignmentFailureCount: 0,
          unknownRoleCount: 0
        }
      },
      {
        id: 'org-consumer-fork',
        repository: 'LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate-fork',
        kind: 'consumer-fork',
        status: 'pass',
        roles: [
          {
            id: 'org-fork-canonical-development',
            role: 'canonical-development-mirror',
            branch: 'develop',
            localRefAlias: null,
            required: true,
            status: 'pass',
            branchExists: true,
            headSha: 'tpl123',
            relationship: {
              tracksRoleId: 'template-canonical-development',
              status: 'pass',
              trackedHeadSha: 'tpl123',
              reason: 'head-sha-match'
            }
          }
        ],
        summary: {
          requiredMissingRoleCount: 0,
          optionalMissingRoleCount: 0,
          alignmentFailureCount: 0,
          unknownRoleCount: 0
        }
      }
    ],
    summary: {
      status: 'pass',
      repositoryCount: 3,
      roleCount: 4,
      requiredMissingRoleCount: 0,
      optionalMissingRoleCount: 0,
      alignmentFailureCount: 0,
      unknownRoleCount: 0
    }
  };
}

function createWakeReport({
  classification,
  status,
  recommendedOwnerRepository,
  reportedRepository = 'LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate',
  reportedBranch = 'develop',
  revalidatedRepository = reportedRepository,
  revalidatedBranch = reportedBranch,
  nextAction = 'test-next-action',
  reason = 'test reason',
  suppressIssueInjection = false,
  suppressDownstreamIssueInjection = false,
  suppressTemplateIssueInjection = false
}) {
  return {
    schema: 'priority/wake-adjudication-report@v1',
    generatedAt: '2026-03-22T00:00:00.000Z',
    wakeKind: 'downstream-onboarding',
    reported: {
      path: 'reported.json',
      generatedAt: '2026-03-22T00:00:00.000Z',
      downstreamRepository: reportedRepository,
      targetBranch: reportedBranch,
      defaultBranch: reportedBranch,
      summaryStatus: classification === 'live-defect' ? 'fail' : 'warn',
      requiredFailCount: classification === 'live-defect' ? 1 : 0,
      warningCount: classification === 'environment-only' ? 1 : 0,
      workflowReferenceCount: 1,
      successfulRunCount: 1,
      requiredFailures: [],
      warnings: []
    },
    revalidated: {
      path: 'revalidated.json',
      generatedAt: '2026-03-22T00:01:00.000Z',
      downstreamRepository: revalidatedRepository,
      targetBranch: revalidatedBranch,
      defaultBranch: revalidatedBranch,
      summaryStatus: classification === 'live-defect' ? 'fail' : classification === 'environment-only' ? 'warn' : 'pass',
      requiredFailCount: classification === 'live-defect' ? 1 : 0,
      warningCount: classification === 'environment-only' ? 1 : 0,
      workflowReferenceCount: 1,
      successfulRunCount: 1,
      requiredFailures: [],
      warnings: [],
      reran: true,
      exitCode: 0
    },
    delta: {
      targetBranchChanged: reportedBranch !== revalidatedBranch,
      defaultBranchChanged: reportedBranch !== revalidatedBranch,
      workflowReferenceCountDelta: 0,
      successfulRunCountDelta: 0,
      reportedRequiredFailureIds: [],
      revalidatedRequiredFailureIds: [],
      clearedRequiredFailureIds: [],
      persistentRequiredFailureIds: [],
      newRequiredFailureIds: []
    },
    summary: {
      classification,
      status,
      suppressIssueInjection,
      suppressDownstreamIssueInjection,
      suppressTemplateIssueInjection,
      recommendedOwnerRepository,
      nextAction,
      reason
    }
  };
}

test('parseArgs captures wake work synthesis paths', () => {
  const parsed = parseArgs([
    'node',
    'wake-work-synthesis.mjs',
    '--policy',
    'policy.json',
    '--wake-adjudication',
    'wake.json',
    '--repo-graph-truth',
    'graph.json',
    '--output',
    'out.json'
  ]);

  assert.equal(parsed.policyPath, 'policy.json');
  assert.equal(parsed.wakeAdjudicationPath, 'wake.json');
  assert.equal(parsed.repoGraphTruthPath, 'graph.json');
  assert.equal(parsed.outputPath, 'out.json');
});

test('synthesizeWakeWork routes branch-target drift into compare governance work', () => {
  const report = synthesizeWakeWork(
    createPolicy(),
    createWakeReport({
      classification: 'branch-target-drift',
      status: 'suppressed',
      recommendedOwnerRepository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      reportedBranch: 'downstream/develop',
      revalidatedBranch: 'develop',
      suppressIssueInjection: true,
      suppressDownstreamIssueInjection: true,
      suppressTemplateIssueInjection: true
    }),
    createRepoGraphTruth()
  );

  assert.equal(report.summary.decision, 'compare-governance-work');
  assert.equal(report.summary.workKind, 'drift-correction');
  assert.equal(report.summary.recommendedOwnerRepository, 'LabVIEW-Community-CI-CD/compare-vi-cli-action');
  assert.equal(report.summary.issueRouting.compareGovernanceWork, true);
  assert.equal(report.roles.governingRole.role, 'consumer-proving-rail');
});

test('synthesizeWakeWork routes canonical live defects into template work', () => {
  const report = synthesizeWakeWork(
    createPolicy(),
    createWakeReport({
      classification: 'live-defect',
      status: 'actionable',
      recommendedOwnerRepository: 'LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate'
    }),
    createRepoGraphTruth()
  );

  assert.equal(report.summary.decision, 'template-work');
  assert.equal(report.summary.workKind, 'defect');
  assert.equal(report.summary.issueRouting.templateWork, true);
});

test('synthesizeWakeWork routes consumer-fork live defects into consumer proving drift work', () => {
  const report = synthesizeWakeWork(
    createPolicy(),
    createWakeReport({
      classification: 'live-defect',
      status: 'actionable',
      recommendedOwnerRepository: 'LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate-fork',
      reportedRepository: 'LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate-fork',
      revalidatedRepository: 'LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate-fork'
    }),
    createRepoGraphTruth()
  );

  assert.equal(report.summary.decision, 'consumer-proving-drift');
  assert.equal(report.summary.workKind, 'drift-correction');
  assert.equal(report.summary.issueRouting.consumerProvingDriftWork, true);
});

test('synthesizeWakeWork falls back to investment work when no repo-graph role matches a live defect', () => {
  const report = synthesizeWakeWork(
    createPolicy(),
    createWakeReport({
      classification: 'live-defect',
      status: 'actionable',
      recommendedOwnerRepository: null,
      reportedRepository: 'example/unknown',
      revalidatedRepository: 'example/unknown'
    }),
    createRepoGraphTruth()
  );

  assert.equal(report.summary.decision, 'investment-work');
  assert.equal(report.summary.workKind, 'investment');
  assert.equal(report.summary.recommendedOwnerRepository, 'LabVIEW-Community-CI-CD/compare-vi-cli-action');
  assert.equal(report.summary.issueRouting.investmentWork, true);
});

test('runWakeWorkSynthesis writes the default output path', async () => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'wake-work-synthesis-default-output-'));
  writeJson(path.join(tmpDir, 'tools', 'policy', 'wake-work-synthesis.json'), createPolicy());
  writeJson(path.join(tmpDir, 'tests', 'results', '_agent', 'issue', 'wake-adjudication.json'), createWakeReport({
    classification: 'environment-only',
    status: 'monitoring',
    recommendedOwnerRepository: 'LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate',
    suppressIssueInjection: true,
    suppressDownstreamIssueInjection: true,
    suppressTemplateIssueInjection: true
  }));
  writeJson(path.join(tmpDir, 'tests', 'results', '_agent', 'handoff', 'downstream-repo-graph-truth.json'), createRepoGraphTruth());

  const { outputPath, report } = await runWakeWorkSynthesis({ repoRoot: tmpDir });

  assert.match(outputPath, new RegExp(DEFAULT_OUTPUT_PATH.replace(/[.*+?^${}()|[\]\\]/g, '\\$&').replace(/\//g, '[\\\\/]')));
  assert.equal(fs.existsSync(outputPath), true);
  assert.equal(report.summary.decision, 'monitor');
  assert.equal(report.summary.status, 'monitoring');
});

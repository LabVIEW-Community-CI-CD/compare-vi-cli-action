import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

import Ajv2020 from 'ajv/dist/2020.js';
import addFormats from 'ajv-formats';

import { runWakeWorkSynthesis } from '../wake-work-synthesis.mjs';

function writeJson(filePath, payload) {
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
  fs.writeFileSync(filePath, `${JSON.stringify(payload, null, 2)}\n`, 'utf8');
}

test('wake work synthesis report matches schema', async () => {
  const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..', '..');
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'wake-work-synthesis-schema-'));
  const policyPath = path.join(tmpDir, 'policy.json');
  const wakePath = path.join(tmpDir, 'wake.json');
  const repoGraphPath = path.join(tmpDir, 'repo-graph.json');
  const outputPath = path.join(tmpDir, 'wake-work-synthesis.json');

  writeJson(policyPath, {
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
  });
  writeJson(wakePath, {
    schema: 'priority/wake-adjudication-report@v1',
    generatedAt: '2026-03-22T00:00:00.000Z',
    wakeKind: 'downstream-onboarding',
    reported: {
      path: 'reported.json',
      generatedAt: '2026-03-22T00:00:00.000Z',
      downstreamRepository: 'LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate',
      targetBranch: 'develop',
      defaultBranch: 'develop',
      summaryStatus: 'fail',
      requiredFailCount: 1,
      warningCount: 0,
      workflowReferenceCount: 1,
      successfulRunCount: 1,
      requiredFailures: [],
      warnings: []
    },
    revalidated: {
      path: 'revalidated.json',
      generatedAt: '2026-03-22T00:01:00.000Z',
      downstreamRepository: 'LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate',
      targetBranch: 'develop',
      defaultBranch: 'develop',
      summaryStatus: 'fail',
      requiredFailCount: 1,
      warningCount: 0,
      workflowReferenceCount: 1,
      successfulRunCount: 1,
      requiredFailures: [],
      warnings: [],
      reran: true,
      exitCode: 0
    },
    delta: {
      targetBranchChanged: false,
      defaultBranchChanged: false,
      workflowReferenceCountDelta: 0,
      successfulRunCountDelta: 0,
      reportedRequiredFailureIds: [],
      revalidatedRequiredFailureIds: [],
      clearedRequiredFailureIds: [],
      persistentRequiredFailureIds: [],
      newRequiredFailureIds: []
    },
    summary: {
      classification: 'live-defect',
      status: 'actionable',
      suppressIssueInjection: false,
      suppressDownstreamIssueInjection: false,
      suppressTemplateIssueInjection: false,
      recommendedOwnerRepository: 'LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate',
      nextAction: 'route-live-downstream-defect',
      reason: 'Live replay still blocks required downstream onboarding checks.'
    }
  });
  writeJson(repoGraphPath, {
    schema: 'priority/downstream-repo-graph-truth@v1',
    generatedAt: '2026-03-22T00:00:00.000Z',
    repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
    policy: {
      path: 'tools/policy/downstream-repo-graph.json',
      compareRepository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action'
    },
    repositories: [
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
      repositoryCount: 1,
      roleCount: 1,
      requiredMissingRoleCount: 0,
      optionalMissingRoleCount: 0,
      alignmentFailureCount: 0,
      unknownRoleCount: 0
    }
  });

  const { report } = await runWakeWorkSynthesis({
    repoRoot: tmpDir,
    policyPath,
    wakeAdjudicationPath: wakePath,
    repoGraphTruthPath: repoGraphPath,
    outputPath
  });

  const schema = JSON.parse(
    fs.readFileSync(path.join(repoRoot, 'docs', 'schemas', 'wake-work-synthesis-report-v1.schema.json'), 'utf8')
  );
  const ajv = new Ajv2020({ allErrors: true, strict: false });
  addFormats(ajv);
  const validate = ajv.compile(schema);
  assert.equal(validate(report), true, JSON.stringify(validate.errors, null, 2));
});

test('checked-in wake work synthesis policy matches schema', () => {
  const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..', '..');
  const policy = JSON.parse(
    fs.readFileSync(path.join(repoRoot, 'tools', 'policy', 'wake-work-synthesis.json'), 'utf8')
  );
  const schema = JSON.parse(
    fs.readFileSync(path.join(repoRoot, 'docs', 'schemas', 'wake-work-synthesis-policy-v1.schema.json'), 'utf8')
  );
  const ajv = new Ajv2020({ allErrors: true, strict: false });
  addFormats(ajv);
  const validate = ajv.compile(schema);
  assert.equal(validate(policy), true, JSON.stringify(validate.errors, null, 2));
});

import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

import Ajv2020 from 'ajv/dist/2020.js';
import addFormats from 'ajv-formats';

import { runHandoffMonitoringMode } from '../handoff-monitoring-mode.mjs';

function writeJson(filePath, payload) {
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
  fs.writeFileSync(filePath, `${JSON.stringify(payload, null, 2)}\n`, 'utf8');
}

test('handoff monitoring mode report matches schema', async () => {
  const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..', '..');
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'handoff-monitoring-schema-'));
  const policyPath = path.join(tmpDir, 'policy.json');
  const queuePath = path.join(tmpDir, 'queue.json');
  const repoGraphPath = path.join(tmpDir, 'repo-graph.json');
  const continuityPath = path.join(tmpDir, 'continuity.json');
  const pivotPath = path.join(tmpDir, 'pivot.json');
  const outputPath = path.join(tmpDir, 'monitoring.json');

  writeJson(policyPath, {
    schema: 'priority/template-monitoring-policy@v1',
    compareRepository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
    pivotTargetRepository: 'LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate',
    repoGraphPolicyPath: 'tools/policy/downstream-repo-graph.json',
    canonicalTemplate: {
      role: 'canonical-template',
      repository: 'LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate',
      branch: 'develop',
      openIssuesMustEqual: 0,
      mustMatchCanonicalBranch: false,
      supportedProof: null
    },
    consumerForks: [],
    unsupportedPaths: [],
    wakeConditions: []
  });
  writeJson(queuePath, {
    schema: 'standing-priority/no-standing@v1',
    reason: 'queue-empty',
    openIssueCount: 0
  });
  writeJson(repoGraphPath, {
    schema: 'priority/downstream-repo-graph-truth@v1',
    generatedAt: '2026-03-22T00:00:00.000Z',
    repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
    policy: {
      path: 'tools/policy/downstream-repo-graph.json',
      compareRepository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action'
    },
    repositories: [],
    summary: {
      status: 'pass',
      repositoryCount: 4,
      roleCount: 7,
      requiredMissingRoleCount: 0,
      optionalMissingRoleCount: 0,
      alignmentFailureCount: 0,
      unknownRoleCount: 0
    }
  });
  writeJson(continuityPath, {
    schema: 'priority/continuity-telemetry-report@v1',
    status: 'maintained',
    continuity: {
      turnBoundary: {
        status: 'safe-idle',
        operatorPromptRequiredToResume: false
      }
    }
  });
  writeJson(pivotPath, {
    schema: 'priority/template-pivot-gate@v1',
    summary: {
      status: 'ready',
      readyForFutureAgentPivot: true,
      pivotDecision: 'future-agent-may-pivot'
    }
  });

  const { report } = await runHandoffMonitoringMode(
    {
      repoRoot: tmpDir,
      policyPath,
      repoGraphTruthPath: repoGraphPath,
      queueEmptyReportPath: queuePath,
      continuitySummaryPath: continuityPath,
      templatePivotGatePath: pivotPath,
      outputPath
    },
    {
      resolveRepoSlugFn: () => 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      runGhJsonFn: (args) => {
        if (args[0] === 'issue') {
          return [];
        }
        if (args[0] === 'api') {
          return { commit: { sha: 'abc123' } };
        }
        return [];
      }
    }
  );

  const ajv = new Ajv2020({ allErrors: true, strict: false });
  addFormats(ajv);
  const schema = JSON.parse(
    fs.readFileSync(path.join(repoRoot, 'docs', 'schemas', 'handoff-monitoring-mode-v1.schema.json'), 'utf8')
  );
  const validate = ajv.compile(schema);
  const valid = validate(report);
  assert.equal(valid, true, JSON.stringify(validate.errors, null, 2));
  assert.equal(report.repoGraph.status, 'pass');
});

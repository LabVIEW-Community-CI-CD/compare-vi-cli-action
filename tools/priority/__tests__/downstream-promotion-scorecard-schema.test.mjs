#!/usr/bin/env node

import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import Ajv2020 from 'ajv/dist/2020.js';
import addFormats from 'ajv-formats';
import { runDownstreamPromotionScorecard } from '../downstream-promotion-scorecard.mjs';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..', '..');

function writeJson(filePath, payload) {
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
  fs.writeFileSync(filePath, `${JSON.stringify(payload, null, 2)}\n`, 'utf8');
}

test('downstream promotion scorecard schema validates generated report payload', async () => {
  const schemaPath = path.join(repoRoot, 'docs', 'schemas', 'downstream-promotion-scorecard-v1.schema.json');
  const schema = JSON.parse(await readFile(schemaPath, 'utf8'));

  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'downstream-promotion-scorecard-schema-'));
  const successReportPath = path.join(tmpDir, 'downstream-onboarding-success.json');
  const feedbackReportPath = path.join(tmpDir, 'downstream-onboarding-feedback.json');
  const templateAgentVerificationReportPath = path.join(tmpDir, 'template-agent-verification-report.json');
  const manifestReportPath = path.join(tmpDir, 'downstream-develop-promotion-manifest.json');
  const outputPath = path.join(tmpDir, 'scorecard.json');

  writeJson(successReportPath, {
    schema: 'priority/downstream-onboarding-success@v1',
    summary: {
      status: 'pass',
      repositoriesEvaluated: 2,
      totalBlockers: 0,
      totalWarnings: 1
    }
  });
  writeJson(feedbackReportPath, {
    schema: 'priority/downstream-onboarding-feedback@v1',
    inputs: {
      downstreamRepository: 'LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate'
    },
    execution: {
      status: 'pass',
      evaluateExitCode: 0,
      successExitCode: 0
    }
  });
  writeJson(templateAgentVerificationReportPath, {
    schema: 'priority/template-agent-verification-report@v1',
    summary: {
      status: 'pass',
      blockerCount: 0,
      recommendation: 'continue-template-agent-loop'
    },
    iteration: {
      label: 'post-merge develop',
      headSha: '1234567890abcdef1234567890abcdef12345678'
    },
    lane: {
      enabled: true,
      reservedSlotCount: 1,
      minimumImplementationSlots: 3,
      implementationSlotsRemaining: 3,
      targetRepository: 'LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate',
      consumerRailBranch: 'downstream/develop'
    },
    verification: {
      provider: 'hosted-github-workflow',
      status: 'pass',
      runUrl: 'https://github.com/example/repo/actions/runs/1'
    },
    provenance: {
      templateDependency: {
        repository: 'LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate',
        version: 'v0.1.1',
        ref: 'v0.1.1',
        cookiecutterVersion: '2.7.1'
      },
      execution: {
        executionPlane: 'linux-tools-image',
        containerImage: 'ghcr.io/labview-community-ci-cd/comparevi-tools:latest',
        generatedConsumerWorkspaceRoot: 'E:/comparevi-template-consumers/example',
        laneId: 'logical-lane-template-verification',
        agentId: 'darwin',
        fundingWindowId: 'invoice-turn-2026-03-HQ1VJLMV-0027'
      }
    },
    goals: {},
    metrics: {
      targetSlotCount: 8,
      reservedSlotCount: 1,
      implementationSlotsRemaining: 3,
      recommendationPresent: true
    },
    blockers: []
  });
  writeJson(manifestReportPath, {
    schema: 'priority/downstream-promotion-manifest@v1',
    promotion: {
      sourceRef: 'upstream/develop',
      sourceCommitSha: '1234567890abcdef1234567890abcdef12345678',
      targetBranch: 'downstream/develop',
      targetBranchClassId: 'downstream-consumer-proving-rail',
      localSourceVerification: {
        attempted: true,
        matched: true
      }
    },
    inputs: {
      compareviToolsRelease: 'v0.6.3-tools.14',
      compareviHistoryRelease: 'v1.3.24',
      scenarioPackIdentity: 'scenario-pack@v1',
      cookiecutterTemplateIdentity: 'LabviewGitHubCiTemplate@v0.1.1'
    }
  });

  const result = runDownstreamPromotionScorecard({
    repo: 'example/repo',
    successReportPath,
    feedbackReportPath,
    templateAgentVerificationReportPath,
    manifestReportPath,
    outputPath
  });

  const report = JSON.parse(await readFile(outputPath, 'utf8'));
  const ajv = new Ajv2020({ allErrors: true, strict: false });
  addFormats(ajv);
  const validate = ajv.compile(schema);
  const valid = validate(report);
  assert.equal(valid, true, JSON.stringify(validate.errors, null, 2));

  assert.equal(result.report.summary.status, 'pass');
  assert.equal(result.report.gates.feedbackReport.status, 'pass');
  assert.equal(result.report.gates.templateAgentVerificationReport.status, 'pass');
  assert.equal(result.report.gates.templateAgentVerificationReport.sourceCommitMatched, true);
  assert.equal(result.report.gates.manifestReport.status, 'pass');
});

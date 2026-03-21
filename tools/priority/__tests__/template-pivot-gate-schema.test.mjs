import '../../shims/punycode-userland.mjs';
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

import Ajv2020 from 'ajv/dist/2020.js';
import addFormats from 'ajv-formats';

import { runTemplatePivotGate } from '../template-pivot-gate.mjs';

const repoRoot = path.resolve(process.cwd());

function writeJson(filePath, payload) {
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
  fs.writeFileSync(filePath, `${JSON.stringify(payload, null, 2)}\n`, 'utf8');
}

test('template pivot gate report matches the checked-in schema', async () => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'template-pivot-gate-schema-'));
  const policyPath = path.join(tmpDir, 'template-pivot-gate.json');
  const queueEmptyReportPath = path.join(tmpDir, 'no-standing-priority.json');
  const releaseSummaryPath = path.join(tmpDir, 'release-summary.json');
  const handoffEntrypointStatusPath = path.join(tmpDir, 'entrypoint-status.json');
  const templateAgentVerificationReportPath = path.join(tmpDir, 'template-agent-verification-report.json');
  const outputPath = path.join(tmpDir, 'template-pivot-gate-report.json');

  writeJson(policyPath, {
    schema: 'priority/template-pivot-gate-policy@v1',
    schemaVersion: '1.0.0',
    sourceRepository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
    targetRepository: 'LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate',
    targetBranch: 'develop',
    queueEmpty: {
      requiredSchema: 'standing-priority/no-standing@v1',
      requiredReason: 'queue-empty',
      requiredOpenIssueCount: 0
    },
    releaseCandidate: {
      requiredSchema: 'agent-handoff/release-v1',
      requireValid: true,
      versionPattern: '^\\d+\\.\\d+\\.\\d+-rc\\.\\d+$',
      versionPatternDescription: 'X.Y.Z-rc.N'
    },
    handoffEntrypoint: {
      requiredSchema: 'agent-handoff/entrypoint-status-v1',
      requiredStatus: 'pass'
    },
    decision: {
      futureAgentOnly: true,
      operatorSteeringAllowed: false,
      requirePreciseSessionFeedback: true
    },
    artifacts: {
      policySchema: 'docs/schemas/template-pivot-gate-policy-v1.schema.json',
      reportSchema: 'docs/schemas/template-pivot-gate-report-v1.schema.json',
      defaultOutputPath: outputPath,
      queueEmptyReportPath,
      releaseSummaryPath,
      handoffEntrypointStatusPath,
      templateAgentVerificationReportPath
    }
  });
  writeJson(queueEmptyReportPath, {
    schema: 'standing-priority/no-standing@v1',
    message: 'queue empty',
    reason: 'queue-empty',
    openIssueCount: 0
  });
  writeJson(releaseSummaryPath, {
    schema: 'agent-handoff/release-v1',
    version: '0.6.3-rc.1',
    valid: true,
    issues: [],
    checkedAt: '2026-03-21T18:00:00.000Z'
  });
  writeJson(handoffEntrypointStatusPath, {
    schema: 'agent-handoff/entrypoint-status-v1',
    generatedAt: '2026-03-21T18:01:00.000Z',
    handoffPath: 'AGENT_HANDOFF.txt',
    maxLines: 80,
    actualLineCount: 42,
    status: 'pass',
    checks: {
      primaryHeading: true,
      lineBudget: true,
      requiredHeadings: true,
      liveArtifactGuidance: true,
      stableEntrypointGuidance: true,
      noStatusLogGuidance: true,
      machineGeneratedArtifactGuidance: true,
      noDatedHistorySections: true
    },
    commands: {
      bootstrap: 'pwsh -NoLogo -NoProfile -File tools/priority/bootstrap.ps1',
      standingPriority: 'pwsh -NoLogo -NoProfile -File tools/Get-StandingPriority.ps1 -Plain',
      printHandoff: 'pwsh -NoLogo -NoProfile -File tools/Print-AgentHandoff.ps1 -ApplyToggles',
      projectPortfolio: 'node tools/npm/run-script.mjs priority:project:portfolio:check',
      developSync: 'node tools/npm/run-script.mjs priority:develop:sync'
    },
    artifacts: {
      priorityCache: '.agent_priority_cache.json',
      router: 'tests/results/_agent/issue/router.json',
      noStandingPriority: 'tests/results/_agent/issue/no-standing-priority.json',
      dockerReviewLoopSummary: 'tests/results/_agent/verification/docker-review-loop-summary.json',
      entrypointStatus: 'tests/results/_agent/handoff/entrypoint-status.json',
      handoffGlob: 'tests/results/_agent/handoff/*.json',
      sessionGlob: 'tests/results/_agent/sessions/*.json'
    },
    violations: []
  });
  writeJson(templateAgentVerificationReportPath, {
    schema: 'priority/template-agent-verification-report@v1',
    generatedAt: '2026-03-21T18:02:00.000Z',
    repo: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
    summary: {
      status: 'pass',
      blockerCount: 0,
      recommendation: 'continue-template-agent-loop'
    },
    iteration: {
      label: 'post-merge #1632',
      ref: 'issue/origin-1632-template-agent-verification-lane',
      headSha: 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
    },
    lane: {
      enabled: true,
      reservedSlotCount: 1,
      minimumImplementationSlots: 3,
      implementationSlotsRemaining: 3,
      executionMode: 'hosted-first',
      targetRepository: 'LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate',
      consumerRailBranch: 'downstream/develop'
    },
    verification: {
      provider: 'hosted-github-workflow',
      status: 'pass',
      durationSeconds: 240,
      runUrl: 'https://github.com/example/run/2'
    },
    goals: {
      maxVerificationLagIterations: 1,
      maxHostedDurationMinutes: 30,
      requireMachineReadableRecommendation: true
    },
    metrics: {
      targetSlotCount: 4,
      reservedSlotCount: 1,
      implementationSlotsRemaining: 3,
      durationWithinGoal: true,
      recommendationPresent: true
    },
    blockers: []
  });

  const { report } = await runTemplatePivotGate(
    {
      policyPath,
      queueEmptyReportPath,
      releaseSummaryPath,
      handoffEntrypointStatusPath,
      templateAgentVerificationReportPath,
      outputPath,
      repo: 'LabVIEW-Community-CI-CD/compare-vi-cli-action'
    },
    {
      resolveRepoSlugFn: (value) => value
    }
  );

  const schema = JSON.parse(
    fs.readFileSync(path.join(repoRoot, 'docs/schemas/template-pivot-gate-report-v1.schema.json'), 'utf8')
  );
  const ajv = new Ajv2020({ allErrors: true, strict: false });
  addFormats(ajv);
  const validate = ajv.compile(schema);
  const valid = validate(report);
  if (!valid) {
    const errors = (validate.errors || [])
      .map((entry) => `${entry.instancePath || '(root)'} ${entry.message}`)
      .join('\n');
    assert.fail(`Template pivot gate report failed schema validation:\n${errors}`);
  }
});

import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

import {
  DEFAULT_HANDOFF_ENTRYPOINT_STATUS_PATH,
  DEFAULT_OUTPUT_PATH,
  DEFAULT_POLICY_PATH,
  DEFAULT_QUEUE_EMPTY_REPORT_PATH,
  DEFAULT_RELEASE_SUMMARY_PATH,
  DEFAULT_TEMPLATE_AGENT_VERIFICATION_REPORT_PATH,
  parseArgs,
  runTemplatePivotGate
} from '../template-pivot-gate.mjs';

function writeJson(filePath, payload) {
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
  fs.writeFileSync(filePath, `${JSON.stringify(payload, null, 2)}\n`, 'utf8');
}

test('parseArgs exposes the checked-in template pivot gate defaults', () => {
  const parsed = parseArgs(['node', 'template-pivot-gate.mjs']);

  assert.equal(parsed.policyPath, DEFAULT_POLICY_PATH);
  assert.equal(parsed.queueEmptyReportPath, DEFAULT_QUEUE_EMPTY_REPORT_PATH);
  assert.equal(parsed.releaseSummaryPath, DEFAULT_RELEASE_SUMMARY_PATH);
  assert.equal(parsed.handoffEntrypointStatusPath, DEFAULT_HANDOFF_ENTRYPOINT_STATUS_PATH);
  assert.equal(parsed.templateAgentVerificationReportPath, DEFAULT_TEMPLATE_AGENT_VERIFICATION_REPORT_PATH);
  assert.equal(parsed.outputPath, DEFAULT_OUTPUT_PATH);
});

test('runTemplatePivotGate reports ready only when queue-empty, rc release, and handoff pass all line up', async () => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'template-pivot-gate-ready-'));
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
    templateDependency: {
      repository: 'LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate',
      version: 'v0.1.1',
      ref: 'v0.1.1',
      cookiecutterVersion: '2.7.1'
    },
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
      handoffEntrypointStatusPath
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
    provenance: {
      templateDependency: {
        repository: 'LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate',
        version: 'v0.1.1',
        ref: 'v0.1.1',
        cookiecutterVersion: '2.7.1'
      },
      execution: {
        executionPlane: 'linux-tools-image',
        containerImage: 'ghcr.io/labview-community-ci-cd/comparevi-tools:v0.1.0',
        generatedConsumerWorkspaceRoot: 'E:\\comparevi-template-consumers\\run-1',
        laneId: 'lane-template-verify',
        agentId: 'darwin',
        fundingWindowId: 'HQ1VJLMV-0027'
      }
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
      now: new Date('2026-03-21T18:05:00.000Z'),
      resolveRepoSlugFn: (value) => value
    }
  );

  assert.equal(report.summary.status, 'ready');
  assert.equal(report.summary.readyForFutureAgentPivot, true);
  assert.equal(report.summary.pivotDecision, 'future-agent-may-pivot');
  assert.equal(report.summary.blockerCount, 0);
  assert.equal(report.evidence.releaseCandidate.matchesVersionPattern, true);
  assert.equal(report.evidence.templateAgentVerification.ready, true);
  assert.equal(report.evidence.templateAgentVerification.templateDependency.matchesPolicy, true);
  assert.equal(report.evidence.templateAgentVerification.execution.complete, true);
  assert.equal(report.policy.operatorSteeringAllowed, false);
  assert.equal(fs.existsSync(outputPath), true);
});

test('runTemplatePivotGate prefers a local authoritative template verification overlay over the checked-in pending seed', async () => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'template-pivot-gate-local-overlay-'));
  const policyPath = path.join(tmpDir, 'template-pivot-gate.json');
  const queueEmptyReportPath = path.join(tmpDir, 'no-standing-priority.json');
  const releaseSummaryPath = path.join(tmpDir, 'release-summary.json');
  const handoffEntrypointStatusPath = path.join(tmpDir, 'entrypoint-status.json');
  const templateAgentVerificationReportPath = path.join(tmpDir, 'template-agent-verification-report.json');
  const templateAgentVerificationLocalReportPath = path.join(tmpDir, 'template-agent-verification-report.local.json');
  const outputPath = path.join(tmpDir, 'template-pivot-gate-report.json');

  writeJson(policyPath, {
    schema: 'priority/template-pivot-gate-policy@v1',
    schemaVersion: '1.0.0',
    sourceRepository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
    targetRepository: 'LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate',
    targetBranch: 'develop',
    templateDependency: {
      repository: 'LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate',
      version: 'v0.1.1',
      ref: 'v0.1.1',
      cookiecutterVersion: '2.7.1'
    },
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
    summary: {
      status: 'pending',
      blockerCount: 0,
      recommendation: 'wait-for-template-verification'
    },
    verification: {
      provider: 'hosted-github-workflow',
      status: 'pending',
      runUrl: null
    },
    lane: {
      targetRepository: 'LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate',
      consumerRailBranch: 'downstream/develop'
    },
    provenance: {
      templateDependency: {
        repository: null,
        version: null,
        ref: null,
        cookiecutterVersion: null
      },
      execution: {
        executionPlane: null,
        containerImage: null,
        generatedConsumerWorkspaceRoot: null,
        laneId: null,
        agentId: null,
        fundingWindowId: null
      }
    }
  });
  writeJson(templateAgentVerificationLocalReportPath, {
    schema: 'priority/template-agent-verification-report@v1',
    generatedAt: '2026-03-21T18:02:00.000Z',
    repo: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
    summary: {
      status: 'pass',
      blockerCount: 0,
      recommendation: 'continue-template-agent-loop'
    },
    iteration: {
      label: 'downstream-promotion 1',
      headSha: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
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
      runUrl: 'https://example.test/runs/2'
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
        containerImage: 'ghcr.io/labview-community-ci-cd/comparevi-tools:v0.1.0',
        generatedConsumerWorkspaceRoot: 'E:\\comparevi-template-consumers\\run-1',
        laneId: 'lane-template-verify',
        agentId: 'darwin',
        fundingWindowId: 'HQ1VJLMV-0027'
      }
    },
    goals: {},
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
      now: new Date('2026-03-21T18:05:00.000Z'),
      resolveRepoSlugFn: (value) => value
    }
  );

  assert.equal(report.summary.status, 'ready');
  assert.equal(report.inputs.templateAgentVerificationReportPath, path.relative(process.cwd(), templateAgentVerificationLocalReportPath).replace(/\\/g, '/'));
  assert.equal(report.evidence.templateAgentVerification.summaryStatus, 'pass');
});

test('runTemplatePivotGate fails closed when the queue is not proven empty or release is not an rc build', async () => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'template-pivot-gate-blocked-'));
  const policyPath = path.join(tmpDir, 'template-pivot-gate.json');
  const releaseSummaryPath = path.join(tmpDir, 'release-summary.json');
  const handoffEntrypointStatusPath = path.join(tmpDir, 'entrypoint-status.json');
  const outputPath = path.join(tmpDir, 'template-pivot-gate-report.json');
  const templateAgentVerificationReportPath = path.join(tmpDir, 'missing-template-agent-verification-report.json');

  writeJson(policyPath, {
    schema: 'priority/template-pivot-gate-policy@v1',
    schemaVersion: '1.0.0',
    sourceRepository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
    targetRepository: 'LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate',
    targetBranch: 'develop',
    templateDependency: {
      repository: 'LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate',
      version: 'v0.1.1',
      ref: 'v0.1.1',
      cookiecutterVersion: '2.7.1'
    },
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
      queueEmptyReportPath: path.join(tmpDir, 'missing-no-standing.json'),
      releaseSummaryPath,
      handoffEntrypointStatusPath,
      templateAgentVerificationReportPath
    }
  });
  writeJson(releaseSummaryPath, {
    schema: 'agent-handoff/release-v1',
    version: '0.6.3',
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

  const { report } = await runTemplatePivotGate(
    {
      policyPath,
      queueEmptyReportPath: path.join(tmpDir, 'missing-no-standing.json'),
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

  assert.equal(report.summary.status, 'blocked');
  assert.equal(report.summary.readyForFutureAgentPivot, false);
  assert.equal(report.summary.pivotDecision, 'stay-in-compare-vi-cli-action');
  assert.ok(report.summary.blockers.some((entry) => entry.code === 'queue-empty-report-missing'));
  assert.ok(report.summary.blockers.some((entry) => entry.code === 'release-not-release-candidate'));
  assert.ok(report.summary.blockers.some((entry) => entry.code === 'template-agent-verification-report-missing'));
  assert.equal(report.evidence.templateAgentVerification.ready, false);
  assert.equal(fs.existsSync(outputPath), true);
});

test('runTemplatePivotGate blocks when template-agent verification is present but not healthy', async () => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'template-pivot-gate-template-blocked-'));
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
      status: 'blocked',
      blockerCount: 1,
      recommendation: 'investigate-template-agent-lane'
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
      status: 'blocked',
      durationSeconds: 240,
      runUrl: 'https://github.com/example/run/3'
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
    blockers: [
      {
        code: 'verification-blocked',
        message: 'Template-agent verification is blocked and needs follow-up.'
      }
    ]
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

  assert.equal(report.summary.status, 'blocked');
  assert.ok(report.summary.blockers.some((entry) => entry.code === 'template-agent-verification-not-pass'));
  assert.equal(report.evidence.templateAgentVerification.summaryStatus, 'blocked');
  assert.equal(report.evidence.templateAgentVerification.ready, false);
});

test('runTemplatePivotGate fails closed when the verification report does not match the pinned template dependency version', async () => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'template-pivot-gate-template-version-mismatch-'));
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
    templateDependency: {
      repository: 'LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate',
      version: 'v0.1.1',
      ref: 'v0.1.1',
      cookiecutterVersion: '2.7.1'
    },
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
    provenance: {
      templateDependency: {
        repository: 'LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate',
        version: 'v0.1.0',
        ref: 'v0.1.0',
        cookiecutterVersion: '2.7.1'
      },
      execution: {
        executionPlane: 'linux-tools-image',
        containerImage: 'ghcr.io/labview-community-ci-cd/comparevi-tools:v0.1.0',
        generatedConsumerWorkspaceRoot: 'E:\\comparevi-template-consumers\\run-1',
        laneId: 'lane-template-verify',
        agentId: 'darwin',
        fundingWindowId: 'HQ1VJLMV-0027'
      }
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

  assert.equal(report.summary.status, 'blocked');
  assert.ok(report.summary.blockers.some((entry) => entry.code === 'template-dependency-version-mismatch'));
  assert.equal(report.evidence.templateAgentVerification.templateDependency.matchesPolicy, false);
  assert.equal(report.evidence.templateAgentVerification.ready, false);
});

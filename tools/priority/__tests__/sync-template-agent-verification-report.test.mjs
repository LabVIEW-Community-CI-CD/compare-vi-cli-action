#!/usr/bin/env node

import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {
  DEFAULT_LOCAL_OVERLAY_REPORT_PATH,
  DEFAULT_LOCAL_REPORT_PATH,
  DEFAULT_OUTPUT_PATH,
  DEFAULT_POLICY_PATH,
  DEFAULT_PROVING_SELECTION_DESTINATION_ROOT,
  DEFAULT_PROVING_SELECTION_OUTPUT_PATH,
  parseArgs,
  syncTemplateAgentVerificationReport
} from '../sync-template-agent-verification-report.mjs';

function writeJson(filePath, payload) {
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
  fs.writeFileSync(filePath, `${JSON.stringify(payload, null, 2)}\n`, 'utf8');
}

test('parseArgs exposes the checked-in template verification sync defaults', () => {
  const parsed = parseArgs(['node', 'sync-template-agent-verification-report.mjs']);
  assert.equal(parsed.policyPath, DEFAULT_POLICY_PATH);
  assert.equal(parsed.localReportPath, DEFAULT_LOCAL_REPORT_PATH);
  assert.equal(parsed.localOverlayReportPath, DEFAULT_LOCAL_OVERLAY_REPORT_PATH);
  assert.equal(parsed.provingSelectionOutputPath, DEFAULT_PROVING_SELECTION_OUTPUT_PATH);
  assert.equal(parsed.provingSelectionDestinationRoot, DEFAULT_PROVING_SELECTION_DESTINATION_ROOT);
  assert.equal(parsed.outputPath, DEFAULT_OUTPUT_PATH);
});

test('syncTemplateAgentVerificationReport prefers hosted downstream proving evidence and writes a local overlay', async (t) => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'template-agent-verification-sync-pass-'));
  t.after(() => fs.rmSync(tmpDir, { recursive: true, force: true }));

  const policyPath = path.join(tmpDir, 'tools', 'priority', 'delivery-agent.policy.json');
  const localReportPath = path.join(tmpDir, 'tests', 'results', '_agent', 'promotion', 'template-agent-verification-report.json');
  const localOverlayReportPath = path.join(tmpDir, 'tests', 'results', '_agent', 'promotion', 'template-agent-verification-report.local.json');
  const authorityReportPath = path.join(tmpDir, 'authority-root', 'template-agent-verification-report.json');
  const hostedAuthorityReportPath = path.join(tmpDir, 'hosted', 'template-agent-verification-report.json');
  const provingSelectionOutputPath = path.join(tmpDir, 'tests', 'results', '_agent', 'promotion', 'selection.json');

  writeJson(policyPath, {
    templateAgentVerificationLane: {
      reportPath: 'tests/results/_agent/promotion/template-agent-verification-report.json',
      authoritativeReportPath: path.relative(tmpDir, authorityReportPath).replace(/\\/g, '/')
    }
  });
  writeJson(localReportPath, {
    schema: 'priority/template-agent-verification-report@v1',
    generatedAt: '2026-03-21T22:44:32.705Z',
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
    provenance: {
      templateDependency: {
        repository: null,
        version: null,
        ref: null,
        cookiecutterVersion: null
      }
    }
  });
  writeJson(hostedAuthorityReportPath, {
    schema: 'priority/template-agent-verification-report@v1',
    generatedAt: '2026-03-22T05:15:00.000Z',
    summary: {
      status: 'pass',
      blockerCount: 0,
      recommendation: 'continue-template-agent-loop'
    },
    iteration: {
      label: 'downstream-promotion 77',
      headSha: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
    },
    lane: {
      targetRepository: 'LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate',
      consumerRailBranch: 'downstream/develop'
    },
    verification: {
      provider: 'hosted-github-workflow',
      status: 'pass',
      runUrl: 'https://example.test/runs/77'
    },
    provenance: {
      templateDependency: {
        repository: 'LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate',
        version: 'v0.1.1',
        ref: 'v0.1.1',
        cookiecutterVersion: '2.7.1'
      }
    }
  });

  const result = await syncTemplateAgentVerificationReport(
    {
      repoRoot: tmpDir,
      policyPath,
      localReportPath,
      localOverlayReportPath,
      authorityReportPath,
      repo: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      expectedSourceSha: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      provingSelectionOutputPath
    },
    {
      resolveRepoSlugFn: (value) => value,
      runResolveDownstreamProvingArtifactFn: async ({ outputPath }) => {
        writeJson(outputPath, { schema: 'priority/downstream-proving-selection@v1', status: 'pass' });
        return {
          status: 'pass',
          reportPath: outputPath,
          selected: {
            templateAgentVerificationStatus: 'pass',
            templateAgentVerificationReportPath: hostedAuthorityReportPath
          }
        };
      }
    }
  );

  assert.equal(result.report.selection.source, 'hosted-authority');
  assert.equal(result.report.selection.synchronizedAuthorityCache, true);
  assert.equal(result.report.selection.synchronizedLocalOverlay, true);
  assert.equal(result.report.localReport.summaryStatus, 'pending');
  assert.equal(result.report.localOverlayReport.summaryStatus, 'pass');
  assert.equal(result.report.authorityReport.summaryStatus, 'pass');
  assert.equal(fs.existsSync(localOverlayReportPath), true);
  assert.equal(fs.existsSync(authorityReportPath), true);
});

test('syncTemplateAgentVerificationReport synthesizes supported template proof authority when downstream proving evidence is unavailable', async (t) => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'template-agent-verification-sync-supported-'));
  t.after(() => fs.rmSync(tmpDir, { recursive: true, force: true }));

  const policyPath = path.join(tmpDir, 'tools', 'priority', 'delivery-agent.policy.json');
  const templatePolicyPath = path.join(tmpDir, 'tools', 'policy', 'template-dependency.json');
  const monitoringModePath = path.join(tmpDir, 'tests', 'results', '_agent', 'handoff', 'monitoring-mode.json');
  const localReportPath = path.join(tmpDir, 'tests', 'results', '_agent', 'promotion', 'template-agent-verification-report.json');
  const localOverlayReportPath = path.join(tmpDir, 'tests', 'results', '_agent', 'promotion', 'template-agent-verification-report.local.json');
  const authorityReportPath = path.join(tmpDir, 'authority-root', 'template-agent-verification-report.json');
  const supportedProofReportPath = path.join(
    tmpDir,
    'tests',
    'results',
    '_agent',
    'promotion',
    'template-agent-verification-report.supported.json'
  );

  writeJson(policyPath, {
    schema: 'priority/delivery-agent-policy@v1',
    workerPool: {
      targetSlotCount: 20
    },
    templateAgentVerificationLane: {
      enabled: true,
      reservedSlotCount: 1,
      minimumImplementationSlots: 3,
      executionMode: 'hosted-first',
      targetRepository: 'LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate',
      consumerRailBranch: 'downstream/develop',
      reportPath: 'tests/results/_agent/promotion/template-agent-verification-report.json',
      authoritativeReportPath: path.relative(tmpDir, authorityReportPath).replace(/\\/g, '/'),
      metrics: {
        maxVerificationLagIterations: 1,
        maxHostedDurationMinutes: 30,
        requireMachineReadableRecommendation: true
      }
    }
  });
  writeJson(templatePolicyPath, {
    schema: 'priority/template-dependency@v1',
    templateRepositorySlug: 'LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate',
    templateReleaseRef: 'v0.1.1',
    rendering: {
      checkout: 'v0.1.1'
    },
    cookiecutterVersion: '2.7.1'
  });
  writeJson(localReportPath, {
    schema: 'priority/template-agent-verification-report@v1',
    generatedAt: '2026-03-21T22:44:32.705Z',
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
    provenance: {
      templateDependency: {
        repository: null,
        version: null,
        ref: null,
        cookiecutterVersion: null
      }
    }
  });
  writeJson(authorityReportPath, {
    schema: 'priority/template-agent-verification-report@v1',
    generatedAt: '2026-03-22T06:33:02.864Z',
    summary: {
      status: 'pass',
      blockerCount: 0,
      recommendation: 'continue-template-agent-loop'
    },
    iteration: {
      label: 'post-release v0.1.1',
      headSha: '89cf3945'
    },
    lane: {
      targetRepository: 'LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate',
      consumerRailBranch: 'downstream/develop'
    },
    verification: {
      provider: 'hosted-github-workflow',
      status: 'pass',
      runUrl: 'https://github.com/LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate/actions/runs/23397184210'
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
        generatedConsumerWorkspaceRoot: null,
        laneId: 'issue/origin-1497-template-v0.1.1',
        agentId: 'Sagan',
        fundingWindowId: null
      }
    },
    goals: {
      maxVerificationLagIterations: 1,
      maxHostedDurationMinutes: 30,
      requireMachineReadableRecommendation: true
    },
    metrics: {
      targetSlotCount: 20,
      reservedSlotCount: 1,
      implementationSlotsRemaining: 19,
      durationWithinGoal: null,
      recommendationPresent: true
    },
    blockers: []
  });
  writeJson(monitoringModePath, {
    schema: 'agent-handoff/monitoring-mode-v1',
    summary: {
      status: 'active'
    },
    templateMonitoring: {
      status: 'pass',
      repositories: [
        {
          role: 'canonical-template',
          repository: 'LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate',
          monitoringStatus: 'pass',
          openIssues: { status: 'pass', count: 0 },
          branchAlignment: null,
          supportedProof: null
        },
        {
          role: 'org-consumer-fork',
          repository: 'LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate-fork',
          monitoringStatus: 'pass',
          openIssues: { status: 'pass', count: 0 },
          branchAlignment: {
            status: 'pass',
            branch: 'develop',
            headSha: 'c3ae46c2b0a02b514b4b08d426302953a87243bc',
            canonicalHeadSha: 'c3ae46c2b0a02b514b4b08d426302953a87243bc'
          },
          supportedProof: {
            status: 'pass',
            workflowFile: 'template-smoke.yml',
            event: 'workflow_dispatch',
            requiredConclusion: 'success',
            runUrl: 'https://github.com/LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate-fork/actions/runs/23567964307',
            headSha: 'c3ae46c2b0a02b514b4b08d426302953a87243bc',
            conclusion: 'success'
          }
        }
      ]
    }
  });

  const result = await syncTemplateAgentVerificationReport(
    {
      repoRoot: tmpDir,
      policyPath,
      templatePolicyPath,
      monitoringModePath,
      localReportPath,
      localOverlayReportPath,
      authorityReportPath,
      supportedProofReportPath,
      repo: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      branch: 'develop',
      expectedSourceSha: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
    },
    {
      resolveRepoSlugFn: (value) => value,
      runResolveDownstreamProvingArtifactFn: async ({ outputPath }) => {
        writeJson(outputPath, { schema: 'priority/downstream-proving-selection@v1', status: 'fail' });
        return {
          status: 'fail',
          reportPath: outputPath,
          selected: null
        };
      }
    }
  );

  const supportedPayload = JSON.parse(fs.readFileSync(supportedProofReportPath, 'utf8'));
  assert.equal(result.report.selection.source, 'supported-proof-authority');
  assert.equal(result.report.selection.synchronizedAuthorityCache, true);
  assert.equal(result.report.selection.synchronizedLocalOverlay, true);
  assert.equal(result.report.supportedProofAuthorityReport.summaryStatus, 'pass');
  assert.equal(result.report.localOverlayReport.runUrl, 'https://github.com/LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate-fork/actions/runs/23567964307');
  assert.equal(result.report.localOverlayReport.templateRef, 'c3ae46c2b0a02b514b4b08d426302953a87243bc');
  assert.equal(supportedPayload.iteration.headSha, 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa');
  assert.equal(supportedPayload.authorityProjection.supportedRole, 'org-consumer-fork');
});

test('syncTemplateAgentVerificationReport keeps current authority when supported proof is stale against the canonical head', async (t) => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'template-agent-verification-sync-stale-proof-'));
  t.after(() => fs.rmSync(tmpDir, { recursive: true, force: true }));

  const policyPath = path.join(tmpDir, 'tools', 'priority', 'delivery-agent.policy.json');
  const monitoringModePath = path.join(tmpDir, 'tests', 'results', '_agent', 'handoff', 'monitoring-mode.json');
  const localReportPath = path.join(tmpDir, 'tests', 'results', '_agent', 'promotion', 'template-agent-verification-report.json');
  const localOverlayReportPath = path.join(tmpDir, 'tests', 'results', '_agent', 'promotion', 'template-agent-verification-report.local.json');
  const authorityReportPath = path.join(tmpDir, 'authority-root', 'template-agent-verification-report.json');
  const supportedProofReportPath = path.join(
    tmpDir,
    'tests',
    'results',
    '_agent',
    'promotion',
    'template-agent-verification-report.supported.json'
  );

  writeJson(policyPath, {
    templateAgentVerificationLane: {
      reportPath: 'tests/results/_agent/promotion/template-agent-verification-report.json',
      authoritativeReportPath: path.relative(tmpDir, authorityReportPath).replace(/\\/g, '/')
    }
  });
  writeJson(localReportPath, {
    schema: 'priority/template-agent-verification-report@v1',
    generatedAt: '2026-03-21T22:44:32.705Z',
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
    provenance: {
      templateDependency: {
        repository: null,
        version: null,
        ref: null,
        cookiecutterVersion: null
      }
    }
  });
  writeJson(authorityReportPath, {
    schema: 'priority/template-agent-verification-report@v1',
    generatedAt: '2026-03-22T06:33:02.864Z',
    summary: {
      status: 'pass',
      blockerCount: 0,
      recommendation: 'continue-template-agent-loop'
    },
    iteration: {
      label: 'post-release v0.1.1',
      headSha: '89cf3945'
    },
    lane: {
      targetRepository: 'LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate',
      consumerRailBranch: 'downstream/develop'
    },
    verification: {
      provider: 'hosted-github-workflow',
      status: 'pass',
      runUrl: 'https://github.com/LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate/actions/runs/23397184210'
    },
    provenance: {
      templateDependency: {
        repository: 'LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate',
        version: 'v0.1.1',
        ref: 'v0.1.1',
        cookiecutterVersion: '2.7.1'
      }
    }
  });
  writeJson(monitoringModePath, {
    schema: 'agent-handoff/monitoring-mode-v1',
    summary: {
      status: 'active'
    },
    templateMonitoring: {
      status: 'pass',
      repositories: [
        {
          role: 'canonical-template',
          repository: 'LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate',
          monitoringStatus: 'pass',
          openIssues: { status: 'pass', count: 0 },
          branchAlignment: null,
          supportedProof: null
        },
        {
          role: 'org-consumer-fork',
          repository: 'LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate-fork',
          monitoringStatus: 'pass',
          openIssues: { status: 'pass', count: 0 },
          branchAlignment: {
            status: 'pass',
            branch: 'develop',
            headSha: 'c3ae46c2b0a02b514b4b08d426302953a87243bc',
            canonicalHeadSha: 'c3ae46c2b0a02b514b4b08d426302953a87243bc'
          },
          supportedProof: {
            status: 'pass',
            workflowFile: 'template-smoke.yml',
            event: 'workflow_dispatch',
            requiredConclusion: 'success',
            runUrl: 'https://github.com/LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate-fork/actions/runs/23567964307',
            headSha: 'ffffffffffffffffffffffffffffffffffffffff',
            conclusion: 'success'
          }
        }
      ]
    }
  });

  const result = await syncTemplateAgentVerificationReport(
    {
      repoRoot: tmpDir,
      policyPath,
      monitoringModePath,
      localReportPath,
      localOverlayReportPath,
      authorityReportPath,
      supportedProofReportPath,
      repo: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      expectedSourceSha: 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
    },
    {
      resolveRepoSlugFn: (value) => value,
      runResolveDownstreamProvingArtifactFn: async ({ outputPath }) => {
        writeJson(outputPath, { schema: 'priority/downstream-proving-selection@v1', status: 'fail' });
        return {
          status: 'fail',
          reportPath: outputPath,
          selected: null
        };
      }
    }
  );

  assert.equal(result.report.selection.source, 'authority');
  assert.equal(result.report.selection.reason, 'shared-authority-current');
  assert.equal(result.report.supportedProofAuthorityReport.exists, false);
  assert.equal(result.report.localOverlayReport.runUrl, 'https://github.com/LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate/actions/runs/23397184210');
  assert.equal(fs.existsSync(supportedProofReportPath), false);
});

test('syncTemplateAgentVerificationReport clears stale overlays when no authoritative evidence is available', async (t) => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'template-agent-verification-sync-fail-'));
  t.after(() => fs.rmSync(tmpDir, { recursive: true, force: true }));

  const policyPath = path.join(tmpDir, 'tools', 'priority', 'delivery-agent.policy.json');
  const localReportPath = path.join(tmpDir, 'tests', 'results', '_agent', 'promotion', 'template-agent-verification-report.json');
  const localOverlayReportPath = path.join(tmpDir, 'tests', 'results', '_agent', 'promotion', 'template-agent-verification-report.local.json');
  const authorityReportPath = path.join(tmpDir, 'authority-root', 'template-agent-verification-report.json');

  writeJson(policyPath, {
    templateAgentVerificationLane: {
      reportPath: 'tests/results/_agent/promotion/template-agent-verification-report.json',
      authoritativeReportPath: path.relative(tmpDir, authorityReportPath).replace(/\\/g, '/')
    }
  });
  writeJson(localReportPath, {
    schema: 'priority/template-agent-verification-report@v1',
    generatedAt: '2026-03-21T22:44:32.705Z',
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
    provenance: {
      templateDependency: {
        repository: null,
        version: null,
        ref: null,
        cookiecutterVersion: null
      }
    }
  });
  writeJson(localOverlayReportPath, {
    stale: true
  });

  const result = await syncTemplateAgentVerificationReport(
    {
      repoRoot: tmpDir,
      policyPath,
      localReportPath,
      localOverlayReportPath,
      authorityReportPath,
      repo: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      expectedSourceSha: 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
    },
    {
      resolveRepoSlugFn: (value) => value,
      runResolveDownstreamProvingArtifactFn: async ({ outputPath }) => {
        writeJson(outputPath, { schema: 'priority/downstream-proving-selection@v1', status: 'fail' });
        return {
          status: 'fail',
          reportPath: outputPath,
          selected: null
        };
      }
    }
  );

  assert.equal(result.report.selection.source, 'none');
  assert.equal(result.report.selection.synchronizedLocalOverlay, false);
  assert.equal(fs.existsSync(localOverlayReportPath), false);
  assert.equal(result.report.localReport.summaryStatus, 'pending');
});

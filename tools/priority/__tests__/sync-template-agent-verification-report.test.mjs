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
        version: 'v0.1.0',
        ref: 'v0.1.0',
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

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
import { syncTemplateAgentVerificationReport } from '../sync-template-agent-verification-report.mjs';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..', '..');

function writeJson(filePath, payload) {
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
  fs.writeFileSync(filePath, `${JSON.stringify(payload, null, 2)}\n`, 'utf8');
}

test('template agent verification sync schema validates generated sync payload', async (t) => {
  const schemaPath = path.join(repoRoot, 'docs', 'schemas', 'template-agent-verification-sync-report-v1.schema.json');
  const schema = JSON.parse(await readFile(schemaPath, 'utf8'));
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'template-agent-verification-sync-schema-'));
  t.after(() => fs.rmSync(tmpDir, { recursive: true, force: true }));

  const policyPath = path.join(tmpDir, 'tools', 'priority', 'delivery-agent.policy.json');
  const localReportPath = path.join(tmpDir, 'tests', 'results', '_agent', 'promotion', 'template-agent-verification-report.json');
  const localOverlayReportPath = path.join(tmpDir, 'tests', 'results', '_agent', 'promotion', 'template-agent-verification-report.local.json');
  const authorityReportPath = path.join(tmpDir, 'authority-root', 'template-agent-verification-report.json');
  const hostedAuthorityReportPath = path.join(tmpDir, 'hosted', 'template-agent-verification-report.json');
  const supportedProofReportPath = path.join(
    tmpDir,
    'tests',
    'results',
    '_agent',
    'promotion',
    'template-agent-verification-report.supported.json'
  );
  const outputPath = path.join(tmpDir, 'sync.json');

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
      supportedProofReportPath,
      repo: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      expectedSourceSha: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      outputPath
    },
    {
      resolveRepoSlugFn: (value) => value,
      runResolveDownstreamProvingArtifactFn: async ({ outputPath: selectionOutputPath }) => {
        writeJson(selectionOutputPath, { schema: 'priority/downstream-proving-selection@v1', status: 'pass' });
        return {
          status: 'pass',
          reportPath: selectionOutputPath,
          selected: {
            templateAgentVerificationStatus: 'pass',
            templateAgentVerificationReportPath: hostedAuthorityReportPath
          }
        };
      }
    }
  );

  const payload = JSON.parse(await readFile(result.outputPath, 'utf8'));
  const ajv = new Ajv2020({ allErrors: true, strict: false });
  addFormats(ajv);
  const validate = ajv.compile(schema);
  const valid = validate(payload);
  assert.equal(valid, true, JSON.stringify(validate.errors, null, 2));
  assert.equal(payload.selection.source, 'hosted-authority');
  assert.equal(payload.localOverlayReport.summaryStatus, 'pass');
  assert.equal(payload.supportedProofAuthorityReport.exists, false);
});

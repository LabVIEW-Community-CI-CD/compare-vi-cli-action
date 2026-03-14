import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

import {
  buildPublicLinuxDiagnosticsWorkflowDispatchReceipt,
  parseArgs,
  runPublicLinuxDiagnosticsWorkflowDispatch
} from '../public-linux-diagnostics-workflow-dispatch.mjs';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..', '..');

test('parseArgs rejects unsupported develop relationship values for hosted dispatch', () => {
  assert.throws(
    () => parseArgs([
      'node',
      'tools/priority/public-linux-diagnostics-workflow-dispatch.mjs',
      '--repository',
      'owner/repo',
      '--reference',
      'develop',
      '--develop-relationship',
      'behind'
    ]),
    /equal, ahead/
  );
});

test('runPublicLinuxDiagnosticsWorkflowDispatch writes a deterministic plan-only hosted receipt', async () => {
  const tempRoot = await fs.promises.mkdtemp(path.join(os.tmpdir(), 'public-linux-dispatch-'));
  const reportPath = path.join(tempRoot, 'public-linux-diagnostics-workflow-dispatch.json');
  const stepSummaryPath = path.join(tempRoot, 'step-summary.md');
  const argv = [
    'node',
    'tools/priority/public-linux-diagnostics-workflow-dispatch.mjs',
    '--repository',
    'LabVIEW-Community-CI-CD/compare-vi-cli-action',
    '--reference',
    'issue/personal-1167-public-linux-harness-workflow',
    '--develop-relationship',
    'ahead',
    '--report',
    reportPath,
    '--step-summary',
    stepSummaryPath
  ];

  const result = await runPublicLinuxDiagnosticsWorkflowDispatch({
    argv,
    environment: {
      GITHUB_REPOSITORY: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      GITHUB_RUN_ID: '123456789',
      GITHUB_SERVER_URL: 'https://github.com'
    },
    now: new Date('2026-03-14T14:30:00Z'),
    execFileFn: async () => ({
      stdout: JSON.stringify({
        visibility: 'public',
        default_branch: 'develop',
        html_url: 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action'
      })
    })
  });

  assert.equal(result.exitCode, 0);
  assert.equal(result.payload.status, 'planned');
  assert.equal(result.payload.execution.hostedWorkflowPath, '.github/workflows/public-linux-diagnostics-harness.yml');
  assert.equal(result.payload.humanGoNoGo.workflowPath, '.github/workflows/human-go-no-go-feedback.yml');
  assert.match(result.payload.execution.localDelegateCommand, /Run-NonLVChecksInDocker\.ps1/);

  const payload = JSON.parse(await readFile(reportPath, 'utf8'));
  assert.equal(payload.execution.workflowRunId, '123456789');
  assert.match(payload.execution.workflowRunUrl, /actions\/runs\/123456789$/);

  const stepSummary = await readFile(stepSummaryPath, 'utf8');
  assert.match(stepSummary, /Public Linux Diagnostics Harness Dispatch/);
  assert.match(stepSummary, /human-go-no-go-feedback\.yml/);
});

test('runPublicLinuxDiagnosticsWorkflowDispatch fails closed for non-public repositories', async () => {
  const argv = [
    'node',
    'tools/priority/public-linux-diagnostics-workflow-dispatch.mjs',
    '--repository',
    'owner/private-repo',
    '--reference',
    'develop',
    '--develop-relationship',
    'equal'
  ];

  await assert.rejects(
    () =>
      runPublicLinuxDiagnosticsWorkflowDispatch({
        argv,
        execFileFn: async () => ({
          stdout: JSON.stringify({
            visibility: 'private',
            default_branch: 'develop',
            html_url: 'https://github.com/owner/private-repo'
          })
        })
      }),
    /not public/
  );
});

test('buildPublicLinuxDiagnosticsWorkflowDispatchReceipt keeps hosted workflow and human decision surfaces separate', () => {
  const payload = buildPublicLinuxDiagnosticsWorkflowDispatchReceipt({
    options: {
      repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      reference: 'develop',
      developRelationship: 'equal',
      reportPath: 'tests/results/_agent/diagnostics/public-linux-diagnostics-workflow-dispatch.json',
      workflowPath: '.github/workflows/public-linux-diagnostics-harness.yml',
      decisionWorkflowPath: '.github/workflows/human-go-no-go-feedback.yml',
      contractSchemaPath: 'docs/schemas/public-linux-diagnostics-harness-contract-v1.schema.json',
      contractDocPath: 'docs/PUBLIC_LINUX_DIAGNOSTICS_HARNESS_CONTRACT.md'
    },
    repositoryInfo: {
      visibility: 'public',
      defaultBranch: 'develop',
      htmlUrl: 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action'
    },
    generatedAt: '2026-03-14T14:30:00Z',
    environment: {
      GITHUB_REPOSITORY: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      GITHUB_RUN_ID: '123456789',
      GITHUB_SERVER_URL: 'https://github.com'
    }
  });

  assert.equal(payload.execution.hostedWorkflowPath, '.github/workflows/public-linux-diagnostics-harness.yml');
  assert.equal(payload.humanGoNoGo.workflowPath, '.github/workflows/human-go-no-go-feedback.yml');
  assert.equal(payload.artifacts.reviewLoopReceiptPath, 'tests/results/docker-tools-parity/review-loop-receipt.json');
});

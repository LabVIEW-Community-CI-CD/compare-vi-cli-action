import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';
import Ajv2020 from 'ajv/dist/2020.js';
import addFormats from 'ajv-formats';

import {
  buildPublicLinuxDiagnosticsHarnessReceipt,
  parseArgs,
  runPublicLinuxDiagnosticsHarness
} from '../public-linux-diagnostics-harness.mjs';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..', '..');

test('parseArgs requires supported develop relationship values', () => {
  assert.throws(
    () =>
      parseArgs([
        'node',
        'tools/priority/public-linux-diagnostics-harness.mjs',
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

test('runPublicLinuxDiagnosticsHarness writes a deterministic planned receipt for a public repository', async () => {
  const tempRoot = await fs.promises.mkdtemp(path.join(os.tmpdir(), 'public-linux-diagnostics-'));
  const reportPath = path.join(tempRoot, 'public-linux-diagnostics-harness-local.json');
  const argv = [
    'node',
    'tools/priority/public-linux-diagnostics-harness.mjs',
    '--repository',
    'LabVIEW-Community-CI-CD/compare-vi-cli-action',
    '--reference',
    'issue/personal-1165-public-linux-harness-local-entry',
    '--develop-relationship',
    'ahead',
    '--report',
    reportPath
  ];

  const result = await runPublicLinuxDiagnosticsHarness({
    argv,
    repoRoot,
    now: new Date('2026-03-14T14:20:00Z'),
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
  assert.equal(result.payload.target.repositoryVisibility, 'public');
  assert.equal(result.payload.target.developRelationship, 'ahead');
  assert.match(result.payload.execution.entryCommand, /Run-NonLVChecksInDocker\.ps1/);
  assert.equal(result.payload.humanGoNoGo.required, true);
  assert.ok(fs.existsSync(reportPath));

  const schema = JSON.parse(
    await readFile(
      path.join(repoRoot, 'docs', 'schemas', 'public-linux-diagnostics-harness-local-v1.schema.json'),
      'utf8'
    )
  );
  const payload = JSON.parse(await readFile(reportPath, 'utf8'));
  const ajv = new Ajv2020({ allErrors: true, strict: false });
  addFormats(ajv);
  const validate = ajv.compile(schema);
  assert.equal(validate(payload), true, JSON.stringify(validate.errors, null, 2));
});

test('runPublicLinuxDiagnosticsHarness fails closed for non-public repositories', async () => {
  const argv = [
    'node',
    'tools/priority/public-linux-diagnostics-harness.mjs',
    '--repository',
    'owner/private-repo',
    '--reference',
    'develop',
    '--develop-relationship',
    'equal'
  ];

  await assert.rejects(
    () =>
      runPublicLinuxDiagnosticsHarness({
        argv,
        repoRoot,
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

test('buildPublicLinuxDiagnosticsHarnessReceipt binds itself to the shared #1163 contract and human decision surface', () => {
  const payload = buildPublicLinuxDiagnosticsHarnessReceipt({
    options: {
      repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      reference: 'develop',
      developRelationship: 'equal',
      reportPath: 'tests/results/_agent/diagnostics/public-linux-diagnostics-harness-local.json',
      contractSchemaPath: 'docs/schemas/public-linux-diagnostics-harness-contract-v1.schema.json',
      contractDocPath: 'docs/PUBLIC_LINUX_DIAGNOSTICS_HARNESS_CONTRACT.md'
    },
    repositoryInfo: {
      visibility: 'public',
      defaultBranch: 'develop',
      htmlUrl: 'https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action'
    },
    generatedAt: '2026-03-14T14:20:00Z',
    repoRoot
  });

  assert.equal(payload.contract.schemaPath, 'docs/schemas/public-linux-diagnostics-harness-contract-v1.schema.json');
  assert.equal(payload.humanGoNoGo.workflowPath, '.github/workflows/human-go-no-go-feedback.yml');
  assert.equal(payload.artifacts.reviewLoopReceiptPath, 'tests/results/docker-tools-parity/review-loop-receipt.json');
});

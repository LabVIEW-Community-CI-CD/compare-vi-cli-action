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
import { runReleaseScorecard } from '../release-scorecard.mjs';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..', '..');

function writeJson(filePath, payload) {
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
  fs.writeFileSync(filePath, `${JSON.stringify(payload, null, 2)}\n`, 'utf8');
}

test('release scorecard schema validates generated scorecard payload', async () => {
  const schemaPath = path.join(repoRoot, 'docs', 'schemas', 'release-scorecard-v1.schema.json');
  const schema = JSON.parse(await readFile(schemaPath, 'utf8'));

  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'release-scorecard-schema-'));
  const ledgerPath = path.join(tmpDir, 'ledger.json');
  const sloPath = path.join(tmpDir, 'slo.json');
  const rollbackPath = path.join(tmpDir, 'rollback.json');
  const trustPath = path.join(tmpDir, 'trust.json');
  const downstreamProvingSelectionPath = path.join(tmpDir, 'downstream-proving-selection.json');
  const downstreamPromotionPath = path.join(tmpDir, 'downstream-promotion.json');
  const outputPath = path.join(tmpDir, 'scorecard.json');

  writeJson(ledgerPath, { gate: { status: 'pass', reason: 'ok' } });
  writeJson(sloPath, {
    breaches: [],
    promotionGate: {
      status: 'pass',
      blockerCount: 0,
      blockers: []
    }
  });
  writeJson(rollbackPath, { summary: { status: 'pass', pausePromotion: false } });
  writeJson(trustPath, { summary: { status: 'pass', failureCount: 0 }, tagSignature: { verified: true, reason: 'valid' } });
  writeJson(downstreamPromotionPath, {
    schema: 'priority/downstream-promotion-scorecard@v1',
    gates: {
      feedbackReport: {
        downstreamRepository: 'LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate'
      }
    },
    summary: {
      status: 'pass',
      blockerCount: 0,
      provenance: {
        sourceCommitSha: '1234567890abcdef1234567890abcdef12345678'
      }
    }
  });
  writeJson(downstreamProvingSelectionPath, {
    schema: 'priority/downstream-proving-selection@v1',
    generatedAt: '2026-03-21T11:00:00.000Z',
    repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
    workflow: 'downstream-promotion.yml',
    branch: 'develop',
    expectedSourceSha: '1234567890abcdef1234567890abcdef12345678',
    artifactPrefix: 'downstream-promotion-',
    status: 'pass',
    selected: {
      run: {
        id: 4201,
        name: 'Downstream Promotion',
        url: 'https://example.test/runs/4201',
        headBranch: 'develop',
        headSha: '1234567890abcdef1234567890abcdef12345678',
        status: 'completed',
        conclusion: 'success',
        createdAt: '2026-03-21T10:00:00.000Z',
        updatedAt: '2026-03-21T10:05:00.000Z'
      },
      artifactName: 'downstream-promotion-4201',
      downloadStatus: 'pass',
      downloadReportPath: path.join(tmpDir, 'download-report.json'),
      scorecardPath: downstreamPromotionPath,
      scorecardStatus: 'pass',
      scorecard: {
        status: 'pass',
        schema: 'priority/downstream-promotion-scorecard@v1',
        summaryStatus: 'pass',
        sourceCommitSha: '1234567890abcdef1234567890abcdef12345678',
        matchedExpectedSourceSha: true,
        targetBranch: 'downstream/develop',
        manifestStatus: 'pass',
        blockerCount: 0,
        downstreamRepository: 'LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate'
      },
      scorecardError: null
    },
    candidates: []
  });

  const result = await runReleaseScorecard({
    repo: 'example/repo',
    stream: 'comparevi-cli',
    channel: 'stable',
    version: '0.6.4',
    tagRef: 'v0.6.4',
    requireDownstreamProving: true,
    requireSignedTag: true,
    ledgerPath,
    sloPath,
    rollbackPath,
    trustPath,
    downstreamProvingSelectionPath,
    downstreamPromotionPath,
    outputPath
  });

  const report = JSON.parse(await readFile(outputPath, 'utf8'));
  const ajv = new Ajv2020({ allErrors: true, strict: false });
  addFormats(ajv);
  const validate = ajv.compile(schema);
  const valid = validate(report);
  assert.equal(valid, true, JSON.stringify(validate.errors, null, 2));

  assert.equal(result.report.summary.status, 'pass');
  assert.equal(result.report.gates.signedTag.status, 'pass');
  assert.equal(result.report.gates.trust.status, 'pass');
  assert.equal(result.report.gates.downstreamProvingSelection.status, 'pass');
  assert.equal(result.report.gates.downstreamPromotion.status, 'pass');
});

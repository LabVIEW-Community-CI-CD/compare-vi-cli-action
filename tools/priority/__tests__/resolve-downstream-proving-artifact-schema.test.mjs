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
import { runResolveDownstreamProvingArtifact } from '../resolve-downstream-proving-artifact.mjs';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..', '..');

function writeJson(filePath, payload) {
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
  fs.writeFileSync(filePath, `${JSON.stringify(payload, null, 2)}\n`, 'utf8');
}

test('downstream proving selection schema validates generated selection payload', async (t) => {
  const schemaPath = path.join(repoRoot, 'docs', 'schemas', 'downstream-proving-selection-v1.schema.json');
  const schema = JSON.parse(await readFile(schemaPath, 'utf8'));
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'downstream-proving-selection-schema-'));
  t.after(() => fs.rmSync(tmpDir, { recursive: true, force: true }));

  const expectedSourceSha = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
  const result = await runResolveDownstreamProvingArtifact(
    {
      repo: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      workflow: 'downstream-promotion.yml',
      branch: 'develop',
      expectedSourceSha,
      destinationRoot: path.join(tmpDir, 'artifacts'),
      outputPath: path.join(tmpDir, 'selection.json')
    },
    {
      async runGhJsonFn() {
        return {
          workflow_runs: [
            {
              id: 202,
              name: 'Downstream Promotion',
              html_url: 'https://example.test/runs/202',
              head_branch: 'develop',
              head_sha: expectedSourceSha,
              status: 'completed',
              conclusion: 'success',
              created_at: '2026-03-21T10:00:00.000Z',
              updated_at: '2026-03-21T10:05:00.000Z'
            }
          ]
        };
      },
      async downloadNamedArtifactsFn({ destinationRoot, reportPath }) {
        const scorecardPath = path.join(destinationRoot, 'downstream-develop-promotion-scorecard.json');
        writeJson(scorecardPath, {
          schema: 'priority/downstream-promotion-scorecard@v1',
          gates: {
            manifestReport: {
              status: 'pass',
              targetBranch: 'downstream/develop'
            },
            feedbackReport: {
              downstreamRepository: 'LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate'
            }
          },
          summary: {
            status: 'pass',
            blockerCount: 0,
            provenance: {
              sourceCommitSha: expectedSourceSha
            }
          }
        });
        writeJson(reportPath, {
          schema: 'run-artifact-download@v1',
          status: 'pass'
        });
        return {
          report: {
            status: 'pass'
          },
          reportPath
        };
      }
    }
  );

  const payload = JSON.parse(await readFile(result.reportPath, 'utf8'));
  const ajv = new Ajv2020({ allErrors: true, strict: false });
  addFormats(ajv);
  const validate = ajv.compile(schema);
  const valid = validate(payload);
  assert.equal(valid, true, JSON.stringify(validate.errors, null, 2));
  assert.equal(payload.status, 'pass');
  assert.equal(payload.selected.run.id, 202);
});

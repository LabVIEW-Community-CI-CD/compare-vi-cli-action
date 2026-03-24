import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';

import { Ajv2020 } from 'ajv/dist/2020.js';
import addFormats from 'ajv-formats';

import { runSubagentEpisode } from '../subagent-episode.mjs';

const repoRoot = path.resolve(process.cwd());

function readJson(filePath) {
  return JSON.parse(fs.readFileSync(filePath, 'utf8'));
}

test('subagent episode report matches schema', async () => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'subagent-episode-schema-'));
  const inputPath = path.join(tmpDir, 'episode-input.json');
  const outputPath = path.join(tmpDir, 'subagent-episode.json');

  fs.writeFileSync(
    inputPath,
    `${JSON.stringify(
      {
        repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
        generatedAt: '2026-03-23T22:10:00Z',
        agent: {
          id: '019d1ba6-746c-72a2-b73c-3ebc239843f1',
          name: 'Hooke',
          role: 'explorer',
          model: 'gpt-5.4-mini'
        },
        task: {
          summary: 'Verify template blocker state',
          class: 'verification',
          issueNumber: 18,
          issueUrl: 'https://github.com/LabVIEW-Community-CI-CD/LabviewGitHubCiTemplate/issues/18'
        },
        execution: {
          status: 'completed',
          lane: 'LabviewGitHubCiTemplate-18-producer-native-consumer',
          executionPlane: 'windows-host',
          dockerLaneId: null,
          hostCapabilityLeaseId: 'lease-hooke-001',
          cellId: 'cell-hooke-001',
          executionCellLeaseId: 'cell-lease-hooke-001',
          dockerLaneLeaseId: null,
          cellClass: 'worker-cell',
          suiteClass: 'template-verification',
          harnessKind: 'teststand-instance',
          harnessInstanceId: 'ts-hooke-001',
          runtimeSurface: 'windows-native-teststand',
          processModelClass: 'sequential',
          operatorAuthorizationRef: null,
          premiumSaganMode: false
        },
        summary: {
          status: 'reported',
          outcome: 'template-blocker-confirmed',
          blocker: 'compare-publication-pending',
          nextAction: 'wait for producer-native release publication'
        },
        evidence: {
          receipts: ['tests/results/_agent/release/release-published-bundle-observer.json']
        },
        cost: {
          observedDurationSeconds: 120,
          tokenUsd: 0.08,
          operatorLaborUsd: 8.333333,
          blendedLowerBoundUsd: 8.413333
        }
      },
      null,
      2
    )}\n`,
    'utf8'
  );

  const { report } = await runSubagentEpisode(
    {
      repoRoot: tmpDir,
      inputPath,
      outputPath
    },
    {
      now: new Date('2026-03-23T22:10:30Z')
    }
  );

  const schema = readJson(path.join(repoRoot, 'docs', 'schemas', 'subagent-episode-report-v1.schema.json'));
  const ajv = new Ajv2020({ allErrors: true, strict: false });
  addFormats(ajv);
  const validate = ajv.compile(schema);
  const valid = validate(report);
  assert.equal(valid, true, JSON.stringify(validate.errors, null, 2));
});

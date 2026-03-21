#!/usr/bin/env node

import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { mkdtempSync } from 'node:fs';
import Ajv2020 from 'ajv/dist/2020.js';
import addFormats from 'ajv-formats';
import { observeConcurrentLaneStatus, parseArgs } from '../concurrent-lane-status.mjs';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..', '..');

function writeJson(filePath, payload) {
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
  fs.writeFileSync(filePath, `${JSON.stringify(payload, null, 2)}\n`, 'utf8');
}

test('concurrent lane status schema validates the generated receipt', async () => {
  const schemaPath = path.join(repoRoot, 'docs', 'schemas', 'concurrent-lane-status-receipt-v1.schema.json');
  const schema = JSON.parse(await readFile(schemaPath, 'utf8'));
  const tempDir = mkdtempSync(path.join(os.tmpdir(), 'concurrent-lane-status-schema-'));
  const applyReceiptPath = path.join(tempDir, 'apply.json');
  writeJson(applyReceiptPath, {
    schema: 'priority/concurrent-lane-apply-receipt@v1',
    generatedAt: '2026-03-21T00:00:00.000Z',
    repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
    status: 'succeeded',
    plan: {
      source: 'file',
      path: 'tests/results/_agent/runtime/concurrent-lane-plan.json',
      schema: 'priority/concurrent-lane-plan@v1',
      recommendedBundleId: 'hosted-only-proof',
      selectedBundle: {
        id: 'hosted-only-proof',
        classification: 'recommended',
        laneIds: ['hosted-linux-proof', 'hosted-windows-proof'],
        reasons: ['test']
      }
    },
    validateDispatch: {
      status: 'dry-run',
      command: ['node', 'tools/npm/run-script.mjs', 'priority:validate', '--'],
      repository: 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
      remote: 'upstream',
      ref: null,
      sampleId: 'ts-20260321-000000-abcd',
      historyScenarioSet: 'smoke',
      reportPath: null,
      runDatabaseId: null,
      error: null
    },
    selectedLanes: [
      {
        id: 'hosted-linux-proof',
        laneClass: 'hosted-proof',
        executionPlane: 'hosted',
        resourceGroup: 'hosted-github',
        availability: 'available',
        decision: 'planned-dispatch',
        reasons: ['hosted-runner-independent-from-local-host'],
        metadata: {}
      },
      {
        id: 'hosted-windows-proof',
        laneClass: 'hosted-proof',
        executionPlane: 'hosted',
        resourceGroup: 'hosted-github',
        availability: 'available',
        decision: 'planned-dispatch',
        reasons: ['hosted-runner-independent-from-local-host'],
        metadata: {}
      }
    ],
    observations: [],
    summary: {
      selectedBundleId: 'hosted-only-proof',
      selectedLaneCount: 2,
      hostedDispatchCount: 0,
      deferredLaneCount: 0,
      hostedLaneIds: ['hosted-linux-proof', 'hosted-windows-proof'],
      deferredLaneIds: [],
      manualLaneIds: [],
      shadowLaneIds: []
    }
  });

  const { receipt } = await observeConcurrentLaneStatus(
    parseArgs(['node', 'concurrent-lane-status.mjs', '--apply-receipt', applyReceiptPath]),
    {
      ensureGhCliFn: () => {},
      getRepoRootFn: () => tempDir,
      resolveUpstreamFn: () => ({ owner: 'LabVIEW-Community-CI-CD', repo: 'compare-vi-cli-action' }),
      runGhJsonFn: () => {
        throw new Error('No GitHub observation expected for dry-run without explicit PR selector.');
      },
      runGhGraphqlFn: () => {
        throw new Error('No PR observation expected for dry-run without explicit PR selector.');
      }
    }
  );

  const ajv = new Ajv2020({ allErrors: true, strict: false });
  addFormats(ajv);
  const validate = ajv.compile(schema);
  assert.equal(validate(receipt), true, JSON.stringify(validate.errors, null, 2));
});

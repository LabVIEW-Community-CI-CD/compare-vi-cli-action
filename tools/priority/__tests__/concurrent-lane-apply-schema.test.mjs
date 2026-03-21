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
import { buildConcurrentLanePlan } from '../concurrent-lane-plan.mjs';
import { applyConcurrentLanePlan, parseArgs } from '../concurrent-lane-apply.mjs';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..', '..');

function createHostPlaneReport() {
  return {
    schema: 'labview-2026-host-plane-report@v1',
    generatedAt: '2026-03-21T00:00:00.000Z',
    host: { os: 'windows', computerName: 'builder' },
    runner: { hostIsRunner: true, runnerName: 'builder', githubActions: false },
    docker: {
      operatorLabels: ['linux-docker-fast-loop', 'windows-docker-fast-loop', 'dual-docker-fast-loop']
    },
    policy: {
      authoritativePlanes: [
        'docker-desktop/linux-container-2026',
        'docker-desktop/windows-container-2026'
      ],
      hostNativeShadowPlane: {
        plane: 'native-labview-2026-32',
        role: 'acceleration-surface',
        authoritative: false,
        executionMode: 'manual-opt-in',
        hostedCiAllowed: false,
        promotionPrerequisites: [
          'docker-desktop/linux-container-2026',
          'docker-desktop/windows-container-2026'
        ]
      }
    },
    native: {
      parallelLabVIEWSupported: true,
      sharedCliAcrossNativePlanes: true,
      recommendedParallelPlanes: ['native-labview-2026-64', 'native-labview-2026-32'],
      planes: {
        x64: { status: 'ready' },
        x32: { status: 'ready' }
      }
    },
    executionPolicy: {
      mutuallyExclusivePairs: {
        pairs: [{ left: 'docker-desktop/linux-container-2026', right: 'docker-desktop/windows-container-2026' }]
      },
      provenParallelPairs: {
        pairs: [{ left: 'native-labview-2026-64', right: 'native-labview-2026-32' }]
      },
      candidateParallelPairs: {
        pairs: [{ left: 'native-labview-2026-64', right: 'native-labview-2026-32' }]
      }
    }
  };
}

test('concurrent lane apply receipt schema validates the generated receipt', async () => {
  const schemaPath = path.join(repoRoot, 'docs', 'schemas', 'concurrent-lane-apply-receipt-v1.schema.json');
  const schema = JSON.parse(await readFile(schemaPath, 'utf8'));
  const plan = buildConcurrentLanePlan({
    hostPlaneReport: createHostPlaneReport(),
    hostRamBudget: {
      schema: 'priority/host-ram-budget@v1',
      selectedProfile: {
        id: 'windows-mirror-heavy',
        recommendedParallelism: 2
      }
    },
    dockerRuntimeSnapshot: {
      schema: 'docker-runtime-determinism@v1',
      observed: {
        osType: 'windows',
        context: 'desktop-windows',
        dockerHost: 'npipe:////./pipe/docker_engine'
      },
      result: {
        status: 'ok'
      }
    }
  });
  const tempDir = mkdtempSync(path.join(os.tmpdir(), 'concurrent-lane-apply-schema-'));
  const planPath = path.join(tempDir, 'concurrent-lane-plan.json');
  const outputPath = path.join(tempDir, 'concurrent-lane-apply-receipt.json');
  fs.writeFileSync(planPath, `${JSON.stringify(plan, null, 2)}\n`, 'utf8');

  const { receipt } = await applyConcurrentLanePlan(
    parseArgs([
      'node',
      'concurrent-lane-apply.mjs',
      '--plan',
      planPath,
      '--output',
      outputPath,
      '--dry-run'
    ]),
    {
      dispatchValidateFn: () => {
        throw new Error('dispatch should not run during dry-run');
      },
      writeValidateDispatchReportFn: () => {
        throw new Error('report should not be written during dry-run');
      }
    }
  );

  const ajv = new Ajv2020({ allErrors: true, strict: false });
  addFormats(ajv);
  const validate = ajv.compile(schema);
  assert.equal(validate(receipt), true, JSON.stringify(validate.errors, null, 2));
});

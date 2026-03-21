#!/usr/bin/env node

import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import Ajv2020 from 'ajv/dist/2020.js';
import addFormats from 'ajv-formats';
import { buildConcurrentLanePlan } from '../concurrent-lane-plan.mjs';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..', '..');

test('concurrent lane plan schema validates the generated report', async () => {
  const schemaPath = path.join(repoRoot, 'docs', 'schemas', 'concurrent-lane-plan-v1.schema.json');
  const schema = JSON.parse(await readFile(schemaPath, 'utf8'));
  const report = buildConcurrentLanePlan({
    hostPlaneReport: {
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
    },
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

  const ajv = new Ajv2020({ allErrors: true, strict: false });
  addFormats(ajv);
  const validate = ajv.compile(schema);
  assert.equal(validate(report), true, JSON.stringify(validate.errors, null, 2));
});

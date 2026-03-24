#!/usr/bin/env node

import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import Ajv from 'ajv';
import addFormats from 'ajv-formats';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..', '..');

test('generated TestStand session schema accepts harness-instance lease identity fields', async () => {
  const schemaPath = path.join(repoRoot, 'docs', 'schema', 'generated', 'teststand-compare-session.schema.json');
  const schema = JSON.parse(await readFile(schemaPath, 'utf8'));

  const ajv = new Ajv({ allErrors: true, strict: false });
  addFormats(ajv);
  const validate = ajv.compile(schema);

  const session = {
    schema: 'teststand-compare-session/v1',
    at: '2026-03-24T03:00:00.000Z',
    warmup: {
      mode: 'skip',
      events: null
    },
    compare: {
      events: 'tests/results/teststand-session/compare/compare-events.ndjson',
      capture: 'tests/results/teststand-session/compare/lvcompare-capture.json',
      report: false,
      sameName: false,
      autoCli: false,
      timeoutSeconds: 600
    },
    outcome: {
      exitCode: 0,
      seconds: 0.5,
      command: 'stub-cli',
      diff: false
    },
    error: null,
    executionCell: {
      cellId: 'exec-cell-mill-01',
      leaseId: 'exec-lease-mill-01',
      leasePath: 'C:/repo/.git/execution-cell-leases/exec-cell-mill-01.json',
      agentId: 'mill',
      agentClass: 'subagent',
      cellClass: 'worker',
      suiteClass: 'single-compare',
      planeBinding: 'native-labview-2026-64',
      runtimeSurface: 'windows-native-teststand',
      premiumSaganMode: false,
      operatorAuthorizationRef: null,
      workingRoot: 'E:/comparevi-lanes/cells/mill-01/work',
      artifactRoot: 'E:/comparevi-lanes/cells/mill-01/artifacts',
      isolatedLaneGroupId:
        'host-os-fingerprint:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
      hostOsFingerprintSha256:
        '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef'
    },
    harnessInstance: {
      harnessKind: 'teststand-compare-harness',
      instanceId: 'lease-harness-mill-01',
      leaseId: 'harness-lease-mill-01',
      leasePath: 'C:/repo/.git/teststand-harness-instance-leases/lease-harness-mill-01.json',
      role: 'single-plane',
      processModelClass: 'sequential-process-model',
      planeBinding: 'native-labview-2026-64',
      parentInstanceId: null
    },
    processModel: {
      runtimeSurface: 'windows-native-teststand',
      processModelClass: 'sequential-process-model',
      windowsOnly: true,
      rootHarnessInstanceId: 'lease-harness-mill-01',
      planeCount: 1
    }
  };

  assert.equal(validate(session), true, JSON.stringify(validate.errors, null, 2));
});

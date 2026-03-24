#!/usr/bin/env node

import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import Ajv2020 from 'ajv/dist/2020.js';
import addFormats from 'ajv-formats';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..', '..');

test('teststand harness-instance lease report schema validates an active coordinator lease', async () => {
  const stateSchemaPath = path.join(
    repoRoot,
    'docs',
    'schemas',
    'teststand-harness-instance-lease-v1.schema.json'
  );
  const reportSchemaPath = path.join(
    repoRoot,
    'docs',
    'schemas',
    'teststand-harness-instance-lease-report-v1.schema.json'
  );
  const stateSchema = JSON.parse(await readFile(stateSchemaPath, 'utf8'));
  const reportSchema = JSON.parse(await readFile(reportSchemaPath, 'utf8'));

  const ajv = new Ajv2020({ allErrors: true, strict: false });
  addFormats(ajv);
  ajv.addSchema(stateSchema, stateSchema.$id);
  const validate = ajv.compile(reportSchema);

  const report = {
    schema: 'priority/teststand-harness-instance-lease-report@v1',
    generatedAt: '2026-03-24T02:00:00.000Z',
    action: 'commit',
    status: 'committed',
    instanceId: 'ts-harness-sagan-01',
    leasePath: 'C:/repo/.git/teststand-harness-instance-leases/ts-harness-sagan-01.json',
    lease: {
      schema: 'priority/teststand-harness-instance-lease@v1',
      generatedAt: '2026-03-24T02:00:00.000Z',
      instanceId: 'ts-harness-sagan-01',
      resourceKind: 'teststand-harness-instance',
      state: 'active',
      sequence: 3,
      heartbeatAt: '2026-03-24T02:00:00.000Z',
      host: {
        isolatedLaneGroupId:
          'host-os-fingerprint:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
        fingerprintSha256:
          '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef'
      },
      request: {
        requestId: 'request-123',
        requestedAt: '2026-03-24T01:58:00.000Z',
        executionCellLeasePath: 'C:/repo/.git/execution-cell-leases/exec-cell-sagan-01.json',
        executionCellId: 'exec-cell-sagan-01',
        executionCellLeaseId: 'exec-lease-sagan-01',
        agentId: 'sagan',
        agentClass: 'sagan',
        cellClass: 'kernel-coordinator',
        suiteClass: 'dual-plane-parity',
        planeBinding: 'dual-plane-parity',
        role: 'coordinator',
        planeKey: null,
        parentInstanceId: null,
        harnessKind: 'teststand-compare-harness',
        runtimeSurface: 'windows-native-teststand',
        processModelClass: 'parallel-process-model',
        premiumSaganMode: true,
        operatorAuthorizationRef: 'premium-authorized-2026-03-24',
        workingRoot: 'E:/comparevi-lanes/cells/sagan-01/work',
        artifactRoot: 'E:/comparevi-lanes/cells/sagan-01/artifacts'
      },
      grant: {
        grantedAt: '2026-03-24T01:59:00.000Z',
        grantor: 'teststand-harness-governor',
        leaseId: 'harness-lease-123',
        ttlSeconds: 1800
      },
      commit: {
        committedAt: '2026-03-24T02:00:00.000Z',
        workingRoot: 'E:/comparevi-lanes/cells/sagan-01/work',
        artifactRoot: 'E:/comparevi-lanes/cells/sagan-01/artifacts'
      },
      release: null
    },
    summary: {
      leaseState: 'active',
      leaseId: 'harness-lease-123',
      executionCellId: 'exec-cell-sagan-01',
      executionCellLeaseId: 'exec-lease-sagan-01',
      agentId: 'sagan',
      agentClass: 'sagan',
      cellClass: 'kernel-coordinator',
      suiteClass: 'dual-plane-parity',
      role: 'coordinator',
      planeKey: null,
      parentInstanceId: null,
      harnessKind: 'teststand-compare-harness',
      runtimeSurface: 'windows-native-teststand',
      processModelClass: 'parallel-process-model',
      premiumSaganMode: true,
      operatorAuthorizationRef: 'premium-authorized-2026-03-24',
      isolatedLaneGroupId:
        'host-os-fingerprint:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
      fingerprintSha256:
        '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
      isStale: false,
      ageSeconds: 0,
      ttlSeconds: 1800,
      workingRoot: 'E:/comparevi-lanes/cells/sagan-01/work',
      artifactRoot: 'E:/comparevi-lanes/cells/sagan-01/artifacts',
      denialReasons: [],
      observations: []
    }
  };

  assert.equal(validate(report), true, JSON.stringify(validate.errors, null, 2));
});

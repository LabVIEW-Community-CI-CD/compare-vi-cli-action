#!/usr/bin/env node

import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import Ajv2020 from 'ajv/dist/2020.js';
import addFormats from 'ajv-formats';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..', '..');

test('execution cell lease report schema validates an active teststand harness lease', async () => {
  const stateSchemaPath = path.join(repoRoot, 'docs', 'schemas', 'execution-cell-lease-v1.schema.json');
  const reportSchemaPath = path.join(repoRoot, 'docs', 'schemas', 'execution-cell-lease-report-v1.schema.json');
  const stateSchema = JSON.parse(await readFile(stateSchemaPath, 'utf8'));
  const reportSchema = JSON.parse(await readFile(reportSchemaPath, 'utf8'));

  const ajv = new Ajv2020({ allErrors: true, strict: false });
  addFormats(ajv);
  ajv.addSchema(stateSchema, stateSchema.$id);
  const validate = ajv.compile(reportSchema);

  const report = {
    schema: 'priority/execution-cell-lease-report@v1',
    generatedAt: '2026-03-24T00:00:00.000Z',
    action: 'commit',
    status: 'committed',
    cellId: 'exec-cell-hooke-01',
    leasePath: 'C:/repo/.git/execution-cell-leases/exec-cell-hooke-01.json',
    policy: {
      operatorId: 'sergio',
      currency: 'USD',
      laborRateUsdPerHour: 250
    },
    lease: {
      schema: 'priority/execution-cell-lease@v1',
      generatedAt: '2026-03-24T00:00:00.000Z',
      cellId: 'exec-cell-hooke-01',
      resourceKind: 'execution-cell',
      state: 'active',
      sequence: 3,
      heartbeatAt: '2026-03-24T00:00:00.000Z',
      host: {
        isolatedLaneGroupId: 'host-os-fingerprint:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
        fingerprintSha256: '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
        platform: 'windows',
        computerName: 'canonical-builder',
        canonical: {
          version: '10.0.26200',
          buildNumber: '26200',
          ubr: 8037
        }
      },
      request: {
        requestId: 'request-123',
        requestedAt: '2026-03-23T23:58:00.000Z',
        agentId: 'hooke',
        agentClass: 'subagent',
        cellClass: 'worker',
        suiteClass: 'dual-plane-parity',
        planeBinding: 'native-labview-2026-dual',
        harnessKind: 'teststand-compare-harness',
        capabilities: ['teststand-harness', 'dual-plane-parity'],
        premiumDualLaneRequested: false,
        operatorId: 'sergio',
        operatorAuthorizationRef: null,
        workingRoot: 'E:/comparevi-lanes/cells/hooke-01/work',
        artifactRoot: 'E:/comparevi-lanes/cells/hooke-01/artifacts'
      },
      grant: {
        grantedAt: '2026-03-23T23:59:00.000Z',
        grantor: 'execution-cell-governor',
        leaseId: 'lease-123',
        ttlSeconds: 1800,
        premiumDualLaneRequested: false,
        premiumSaganMode: false,
        policyDecision: 'ordinary-execution-cell',
        grantedCapabilities: ['teststand-harness', 'dual-plane-parity'],
        billableRateMultiplier: 1,
        billableRateUsdPerHour: 250
      },
      commit: {
        committedAt: '2026-03-24T00:00:00.000Z',
        harnessInstanceId: 'harness-hooke-01',
        workingRoot: 'E:/comparevi-lanes/cells/hooke-01/work',
        artifactRoot: 'E:/comparevi-lanes/cells/hooke-01/artifacts'
      },
      release: null
    },
    summary: {
      leaseState: 'active',
      leaseId: 'lease-123',
      holder: 'hooke',
      agentClass: 'subagent',
      cellClass: 'worker',
      harnessKind: 'teststand-compare-harness',
      harnessInstanceId: 'harness-hooke-01',
      suiteClass: 'dual-plane-parity',
      planeBinding: 'native-labview-2026-dual',
      premiumSaganMode: false,
      billableRateMultiplier: 1,
      billableRateUsdPerHour: 250,
      operatorAuthorizationRef: null,
      isolatedLaneGroupId: 'host-os-fingerprint:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
      fingerprintSha256: '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
      workingRoot: 'E:/comparevi-lanes/cells/hooke-01/work',
      artifactRoot: 'E:/comparevi-lanes/cells/hooke-01/artifacts',
      isStale: false,
      ageSeconds: 0,
      ttlSeconds: 1800,
      denialReasons: [],
      observations: []
    }
  };

  assert.equal(validate(report), true, JSON.stringify(validate.errors, null, 2));
});
